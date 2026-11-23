# frozen_string_literal: true
# tools/gcviz/gcviz-events.rb -- reads a SPINEL_GC_EVENTS file (written by the
# events runtime, vendor/spinel lib/sp_slab.c under SP_GC_EVENTS).
#
#   ruby gcviz-events.rb summary EVENTS        counts by event kind
#   ruby gcviz-events.rb json EVENTS [BINARY]  the replay as JSON on stdout;
#                                              BINARY names classes via nm and
#                                              source lines via llvm-symbolizer
#                                              (LLVM_SYMBOLIZER selects it)
#   ruby gcviz-events.rb check EVENTS          replay invariants; exit 1 on a
#                                              violation
module GcvizEvents
  HEADER = 'a8 L< L< Q< Q<'
  RECORD = 'L< L< Q< Q< L< S< S<'
  REC_SIZE = 32
  KIND = {
    1 => :alloc_obj, 2 => :alloc_str, 3 => :alloc_raw, 4 => :set_fin,
    5 => :relive0, 15 => :relive1, 6 => :free, 7 => :swept, 8 => :parked0,
    18 => :parked1, 9 => :pin, 30 => :survived0, 31 => :survived1,
    40 => :take0, 41 => :take1, 42 => :take_raw0, 43 => :take_raw1,
    100 => :cycle, 101 => :root, 200 => :census, 300 => :mark,
    400 => :site, 401 => :cycle_site,
    # blocks malloc'd outside the slab: allocated, taken back from a pool,
    # freed, swept from a list, survived a young list sweep
    11 => :malloc_obj, 14 => :malloc_pool, 12 => :malloc_str, 13 => :malloc_raw, 16 => :free, 17 => :swept, 32 => :survived_list
  }.freeze
  MALLOC = { malloc_obj: :alloc_obj, malloc_pool: :alloc_obj, malloc_str: :alloc_str, malloc_raw: :alloc_raw }.freeze
  ALLOCS = %i[alloc_obj alloc_str alloc_raw].freeze
  Event = Struct.new(:seq, :cycle, :addr, :extra, :size, :what, :aux)

  module_function

  def read(path)
    data = File.binread(path)
    magic, version, rec_size, count, dropped = data.unpack(HEADER)
    raise "#{path}: not an events file" unless magic == "SPGCEV1\0" && version == 1
    raise "#{path}: record size #{rec_size}, want #{REC_SIZE}" unless rec_size == REC_SIZE
    body = data.byteslice(32, count * REC_SIZE)
    raise "#{path}: truncated (#{count} records announced)" unless body && body.bytesize == count * REC_SIZE
    events = Array.new(count) { |i| Event.new(*body.unpack(RECORD, offset: i * REC_SIZE)) }
    { count: count, dropped: dropped, events: events }
  end

  # Replays slot lives. A life starts at an allocation (1/2/3, malloc'd
  # 11/12/13, from a pool 14) or a relive (5/15) and ends at a free (6/16)
  # or a sweep (7/8/18/17). An allocation's stack
  # frames (400) follow its record. Returns the lives and the violations
  # found on the way.
  def replay(events)
    live = {}
    lives = []
    errors = []
    events.each do |e|
      k = KIND[e.what]
      heap = MALLOC.key?(k) ? :malloc : :slab
      k = MALLOC.fetch(k, k)
      case k
      when :alloc_obj, :alloc_str, :alloc_raw, :relive0, :relive1
        errors << "seq #{e.seq}: #{k} of live slot 0x#{e.addr.to_s(16)}" if live[e.addr]
        l = { id: lives.size, addr: e.addr, size: e.size, kind: k, born: e.seq, born_cycle: e.cycle,
              bytes: k == :alloc_obj ? e.aux : nil, scan: k == :alloc_obj ? e.extra : nil, promoted: nil, died: nil, died_cycle: nil, how: nil, heap: heap }
        live[e.addr] = l
        lives << l
      when :site
        l = live[e.addr]
        (l[:ips] ||= []) << e.extra if l && ALLOCS.include?(l[:kind])
      when :free, :swept, :parked0, :parked1
        l = live.delete(e.addr)
        if l
          l[:died] = e.seq
          l[:died_cycle] = e.cycle
          l[:how] = k
        elsif k != :free
          errors << "seq #{e.seq}: #{k} of a slot never allocated, 0x#{e.addr.to_s(16)}"
        end
      when :survived0, :survived1, :survived_list
        l = live[e.addr]
        if !l
          errors << "seq #{e.seq}: #{k} of a slot not live, 0x#{e.addr.to_s(16)}"
        elsif e.aux == 1 && l[:promoted].nil?
          l[:promoted] = e.seq
        end
      end
    end
    { lives: lives, live: live, errors: errors }
  end

  # Source lines for return addresses, through llvm-symbolizer and the
  # binary's debug information. Spinel writes #line directives naming the
  # Ruby file, so a frame in compiled Ruby resolves to a .rb line; frames in
  # the runtime resolve to .c/.h files and are left out. Returns
  # { ip => [[file, line], ...] }, the innermost (inlined) frame first.
  def symbolize(bin, ips, tool = ENV.fetch('LLVM_SYMBOLIZER', 'llvm-symbolizer'))
    ips = ips.uniq.select(&:positive?)
    return {} if ips.empty?
    out = IO.popen([tool, "--obj=#{bin}", '--inlining', '--functions=none'], 'r+') do |io|
      ips.each { |ip| io.puts format('0x%x', ip - 1) } # a return address points past its call
      io.close_write
      io.read
    end
    blocks = out.split("\n\n")
    raise "llvm-symbolizer answered #{blocks.size} of #{ips.size} addresses" unless blocks.size == ips.size

    ips.zip(blocks).to_h do |ip, b|
      [ip, b.lines.filter_map { |loc| (m = loc.chomp.match(/\A(.*\.rb):(\d+):\d+\z/)) && [m[1], m[2].to_i] }]
    end
  end

  # The .rb lines of a stack, nearest the allocator first, each line once.
  def lines_of(ips, sym)
    (ips || []).flat_map { |ip| sym[ip] || [] }.uniq
  end

  def check(file)
    r = replay(file[:events])
    errors = r[:errors].dup
    errors << "#{file[:dropped]} records dropped" if file[:dropped].positive?
    census = file[:events].select { |e| e.what == 200 }.map(&:addr)
    # the census walks the slab: a run with the slab off has none
    errors << 'no census at exit' if census.empty? && r[:lives].any? { |l| l[:heap] == :slab }
    # the census names every slab slot still allocated; replay knows the ones
    # it saw born (raw payload takes are not allocations, so census may name
    # more, never fewer)
    # a payload malloc'd outside the slab is on no list, so the census names slab slots only
    missing = r[:live].select { |_, l| l[:heap] == :slab }.keys - census
    errors << "#{missing.size} slots live in the replay but absent from the census" unless missing.empty?
    cycles = file[:events].count { |e| e.what == 100 }
    errors << 'no collection happened' if cycles.zero?
    if file[:events].any? { |e| e.what == 400 }
      bare = r[:lives].count { |l| ALLOCS.include?(l[:kind]) && !l[:ips] }
      errors << "#{bare} allocations without the stack that made them" if bare.positive?
    end
    errors
  end

  def to_json_data(file, bin)
    names = {}
    if bin
      IO.popen(['nm', bin], &:read).each_line do |line|
        a, t, n = line.split
        names[a.to_i(16)] = n if n && t =~ /[tT]/ && n.start_with?('sp_', '_sp_')
      end
    end
    r = replay(file[:events])
    cyc_ips = []
    file[:events].each do |e|
      cyc_ips << [] if e.what == 100
      cyc_ips.last << e.extra if e.what == 401 && cyc_ips.last
    end
    sym = bin ? symbolize(bin, r[:lives].flat_map { |l| l[:ips] || [] } + cyc_ips.flatten) : {}
    # the program's own file: the .rb most frames resolve to
    source = sym.values.flatten(1).map(&:first).tally.max_by(&:last)&.first
    rb = ->(ips) { lines_of(ips, sym).select { |f, _| f == source }.map(&:last) }
    cycles = file[:events].select { |e| e.what == 100 }.each_with_index.map do |e, i|
      { seq: e.seq, cycle: e.cycle, full: e.aux & 1 == 1, minor: e.aux & 2 == 2, roots: e.size, bytes: e.extra,
        lines: rb.(cyc_ips[i]) }
    end
    {
      records: file[:count], dropped: file[:dropped], source: source,
      cycles: cycles,
      roots: file[:events].select { |e| e.what == 101 }.map { |e| { seq: e.seq, slot: e.addr, entry: e.size, tag: e.aux, value: e.extra } },
      marks: file[:events].select { |e| e.what == 300 }.map { |e| { seq: e.seq, id: e.extra } },
      lives: r[:lives].map do |l|
        scan = l[:scan] && (l[:scan].zero? ? 'none' : names[l[:scan]] || format('0x%x', l[:scan]))
        l.except(:ips).merge(scan: scan, lines: rb.(l[:ips]))
      end
    }
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, path, bin = ARGV
  abort 'usage: gcviz-events.rb summary|json|check EVENTS [BINARY]' unless cmd && path
  file = GcvizEvents.read(path)
  case cmd
  when 'summary'
    puts "records #{file[:count]} dropped #{file[:dropped]}"
    file[:events].group_by(&:what).sort.each do |w, es|
      puts format('%-4d %-10s %d', w, GcvizEvents::KIND[w] || '?', es.size)
    end
  when 'check'
    errors = GcvizEvents.check(file)
    errors.first(20).each { |m| warn m }
    abort "gcviz check: #{errors.size} violations" unless errors.empty?
    puts 'gcviz check: ok'
  when 'json'
    require 'json'
    puts JSON.generate(GcvizEvents.to_json_data(file, bin))
  else
    abort "unknown command #{cmd}"
  end
end
