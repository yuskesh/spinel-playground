# frozen_string_literal: true
#
# tools/doom/emit-schema.rb — decision 0008 task 5's schema emitter.
#
#   ruby tools/doom/emit-schema.rb --inventory FILE --setup-writes FILE
#                                  --schema FILE --access FILE
#
# Both inputs are the audit's: `state-use.tsv` and `setup-writes.tsv`.
#
# `state.tsv` is written FROM the audit's inventory, not by hand. Every column
# it needs the audit already decided and can defend:
#
#   name      the class and ivar, flattened -- names are globally unique
#   role      derived from where the accesses are
#   element   from the disposition, which the reader's type and the role decide
#   count     from the allocation site, through tools/doom/core-counts.tsv
#   initial   0, or prepared:NAME for a prepared value
#   origin    Class@ivar, which is what `--inventory` matches against
#   writers   the owning subsystem, declared per class
#
# Writing it by hand would be 475 rows nobody could check against the code;
# emitting it means a field that moves in the source moves here, and the audit
# is what decides whether the move is allowed.
#
# `access.tsv` lists each participating buffer once per entry with its mode,
# from the domains the audit measured and the roles it derived: an entry that
# only reads a buffer asks for `in`, one that writes it asks for `inout`.

require "optparse"
require "fileutils"
require "set"

PROG = "emit-schema"
# The buffer elements of the CORE boundary (decision 0018 added i8, u16 and i16).
ELEMENTS = %w[u8 i8 u16 i16 i32 u32 i64].freeze
WIDTH = { "u8" => 1, "i8" => 1, "u16" => 2, "i16" => 2, "i32" => 4, "u32" => 4, "i64" => 8 }.freeze
opt = {}
OptionParser.new do |o|
  o.on("--inventory FILE") { |v| opt[:inventory] = v }
  o.on("--schema FILE") { |v| opt[:schema] = v }
  o.on("--access FILE") { |v| opt[:access] = v }
  o.on("--prepared FILE") { |v| opt[:prepared] = v }
  o.on("--catalog FILE") { |v| opt[:catalog] = v }
  o.on("--representations FILE") { |v| opt[:representations] = v }
  o.on("--held FILE") { |v| opt[:held] = v }
  o.on("--setup-writes FILE") { |v| opt[:setup_writes] = v }
  o.on("--unreached FILE") { |v| opt[:unreached] = v }
  o.on("--added FILE") { |v| opt[:added] = v }
  o.on("--widths FILE") { |v| opt[:widths] = v }
end.parse!
%i[inventory schema access setup_writes].each do |k|
  opt[k] or abort("#{PROG}: --#{k.to_s.tr('_', '-')} is required")
end
File.exist?(opt[:setup_writes]) or abort("#{PROG}: no setup writes at #{opt[:setup_writes]}")

# WHAT FULL'S SETUP WRITES, from the audit's `setup-writes.tsv`: each field some
# definition reached from bin/doom.rb's setup writes other than by allocating
# it. A field ABSENT from it keeps its fill -- so what is absent has to be
# evidence, and only a COMPLETE walk makes it so. Read strictly:
#
#   * every line is one of the known kinds: a comment, `#root`, the one header,
#     a field row, `#gap`, and `#complete` -- last, exactly once;
#   * `#complete` states roots, definitions, fields and gaps, and the file has
#     to hold exactly that many `#root` lines and field rows;
#   * a field row is `Class@@ivar` and a non-empty writer list, each field once;
#   * any gap refuses the file.
#
# Mac review of 39e4392 gave the old reader an empty file, a comment-only file
# and a file with no header, and each was accepted as "setup writes nothing"
# -- every fill kept. A truncated file read the same way.
setup_writes = {}
SW = opt[:setup_writes]
sw_refuse = ->(i, why) { abort("#{PROG}: #{SW}#{i ? ":#{i}" : ''}: #{why}; a field it does not list is then not shown to keep its fill") }
sw_roots = 0
sw_header = nil
sw_complete = nil
sw_last = nil
File.foreach(SW).with_index(1) do |ln, i|
  line = ln.chomp
  next if line.strip.empty?
  sw_last = i
  sw_complete and sw_refuse.call(i, "a line after #complete")
  f = line.split("\t", -1)
  if f[0] == "#gap"
    sw_refuse.call(i, "the setup walk has a gap (#{f[1..].join(' ')})")
  elsif f[0] == "#root"
    (f.length == 2 && f[1] =~ /\A[A-Z]\w*#\S+\z/) or sw_refuse.call(i, "a #root line is not `#root<TAB>Class#method`")
    sw_header and sw_refuse.call(i, "a #root line after the header")
    sw_roots += 1
  elsif f[0] == "#complete"
    sw_complete and sw_refuse.call(i, "#complete appears twice")
    # EACH KEY ONCE, checked before the pairs become a hash: `fields=99
    # fields=1` used to collapse to the last value and be accepted.
    pairs = f[1..].map { |p| p.split("=", 2) }
    pairs.all? { |p| p.length == 2 } or sw_refuse.call(i, "#complete holds a field that is not key=count")
    keys = pairs.map(&:first)
    keys.uniq.length == keys.length or
      sw_refuse.call(i, "#complete states #{(keys.select { |k| keys.count(k) > 1 }.uniq).join(', ')} more than once")
    kv = pairs.to_h
    (kv.keys.sort == %w[definitions fields gaps roots] && kv.values.all? { |v| v =~ /\A(0|[1-9][0-9]*)\z/ }) or
      sw_refuse.call(i, "#complete must state roots, definitions, fields and gaps as counts")
    sw_complete = kv.transform_values { |v| Integer(v, 10) }
  elsif line.start_with?("#")
    next
  elsif f == %w[field writers]
    sw_header and sw_refuse.call(i, "the header appears twice")
    sw_header = i
  else
    sw_header or sw_refuse.call(i, "a row before the `field<TAB>writers` header")
    f.length == 2 or sw_refuse.call(i, "#{f.length} column(s), want 2")
    f[0] =~ /\A[A-Z]\w*@@\w+\z/ or sw_refuse.call(i, "#{f[0].inspect} is not Class@@ivar")
    f[1].strip.empty? and sw_refuse.call(i, "#{f[0]} names no writer")
    setup_writes.key?(f[0]) and sw_refuse.call(i, "#{f[0]} is listed twice")
    setup_writes[f[0]] = f[1]
  end
end
sw_complete or sw_refuse.call(nil, "no #complete line: the walk did not finish writing this file")
sw_header or sw_refuse.call(nil, "no `field<TAB>writers` header")
sw_complete["gaps"].zero? or sw_refuse.call(nil, "#complete counts #{sw_complete['gaps']} gap(s)")
sw_complete["roots"] == sw_roots && sw_roots.positive? or
  sw_refuse.call(nil, "#complete says #{sw_complete['roots']} root(s) and the file lists #{sw_roots}")
sw_complete["fields"] == setup_writes.length or
  sw_refuse.call(nil, "#complete says #{sw_complete['fields']} field(s) and the file lists #{setup_writes.length}")
sw_complete["definitions"].positive? or sw_refuse.call(nil, "#complete says the walk reached no definition")
File.exist?(opt[:inventory]) or abort("#{PROG}: no inventory at #{opt[:inventory]}")

COLS = %w[class ivar role owner element disposition stored-element count initial
          domains writers readers writes-outside reads-outside].freeze
rows = []
header = nil
File.foreach(opt[:inventory]).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  if header.nil?
    header = f
    header == COLS or
      abort("#{PROG}: #{opt[:inventory]}:#{i}: the inventory's columns are " \
            "#{f.join(', ')}, and this reads #{COLS.join(', ')}")
    next
  end
  rows << COLS.zip(f).to_h
end
rows.empty? and abort("#{PROG}: the inventory holds no fields")

# One name per field, and globally unique. `Game@@mobj_x` becomes
# `game_mobj_x`; a collision would mean two classes with one ivar name, which
# is refused rather than disambiguated, because a generated suffix is a name
# nobody reading the source would recognise.
def flatten_name(cls, ivar)
  "#{cls}_#{ivar.sub(/\A@+/, '')}".gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase
end

ENTRY_OF = { "input" => "doom_core_input", "step" => "doom_core_step",
             "render" => "doom_core_render" }.freeze

# What the catalog already gives a count for. A prepared field whose count is
# one of those names its length THERE rather than restating it, so the two
# cannot drift; a prepared field with a `fixed:` count needs a row of its own.
catalog_counts = {}
if opt[:catalog] && File.exist?(opt[:catalog])
  File.foreach(opt[:catalog]) do |ln|
    next if ln.start_with?("#") || ln.strip.empty?
    f = ln.chomp.split("\t", -1)
    catalog_counts[f[1]] = Integer(f[2], 10) if f[0] == "count"
  end
end

# Fields whose schema shape is not their ivar's shape. Read before the rows so
# a row can be replaced as it is emitted.
REP_PATH = opt[:representations] || File.join(__dir__, "core-representations.tsv")
representations = {}
taken = {}
if File.exist?(REP_PATH)
  File.foreach(REP_PATH).with_index(1) do |ln, i|
    next if ln.start_with?("#") || ln.strip.empty?
    f = ln.chomp.split("\t", -1)
    # Five columns, or six: the sixth names the Full producer of a field whose
    # value is a CONVERSION of the original's (Resources reads it; the emitter
    # only carries the table).
    [5, 6].include?(f.length) or abort("#{PROG}: #{REP_PATH}:#{i}: #{f.length} column(s), want 5 or 6")
    key, nm, el, cnt, why, producer = f
    why.strip.empty? and abort("#{PROG}: #{REP_PATH}:#{i}: #{key} needs a reason")
    representations.key?(key) and abort("#{PROG}: #{REP_PATH}:#{i}: #{key} is listed twice")
    # A FOLD: the ivar leaves the schema because what it held is carried by
    # fields that already exist -- `Renderer@@dc_srcbuf`, a reference to a
    # buffer, becomes the selector and base in `renderer_dc_srcres` and
    # `renderer_dc_srcbase`. The targets must be emitted, or it is refused.
    if nm.start_with?("fold:")
      (el == "-" && cnt == "-") or abort("#{PROG}: #{REP_PATH}:#{i}: a fold has no element or count of its own")
      targets = nm.delete_prefix("fold:").split("+")
      targets.empty? and abort("#{PROG}: #{REP_PATH}:#{i}: a fold names no field")
      representations[key] = { "fold" => targets }
      next
    end
    # AN ALIAS: the ivar is the SAME STORAGE as a field the schema already has --
    # `JobExecutor@@wall` is `jobs.wall_bank`, handed over at construction -- so
    # it gets no allocation of its own. Unlike a fold nothing is converted: the
    # target must have this ivar's element and count, the entries that reach
    # this ivar reach the target, and the mapping is written into the schema as
    # an `#alias` line so it is not only in this table. Whether the original
    # really holds one object is not this file's to know; the reference checks
    # it on the objects the original builds.
    if nm.start_with?("alias:")
      (el == "-" && cnt == "-") or abort("#{PROG}: #{REP_PATH}:#{i}: an alias has no element or count of its own")
      target = nm.delete_prefix("alias:")
      target =~ /\A[a-z0-9_]+\z/ or abort("#{PROG}: #{REP_PATH}:#{i}: an alias names one field, not #{target.inspect}")
      representations[key] = { "alias" => target }
      next
    end
    ELEMENTS.include?(el) or abort("#{PROG}: #{REP_PATH}:#{i}: element #{el.inspect}")
    cnt =~ /\A(fixed|level|screen|limit|table):/ or
      abort("#{PROG}: #{REP_PATH}:#{i}: count #{cnt.inspect} is not 0008's grammar")
    taken.key?(nm) and abort("#{PROG}: #{REP_PATH}:#{i}: #{nm} is already a replacement name")
    # AN ADDED FIELD, `Class@@ivar.part`: one more field emitted right after its
    # ivar's own row, standing for a part of what that ivar held -- the base of
    # `@ds_source`, beside its selector. Its origin is the key, which names the
    # ivar and the part.
    representations[key] = { "name" => nm, "element" => el, "count" => cnt, "producer" => producer }
    taken[nm] = key
  end
end

# Stored fields that would be carried by Full -- UNDERIVED, or written by setup --
# and are not carried yet, each with its reason.
HELD_PATH = opt[:held] || File.join(__dir__, "core-initials-held.tsv")
held = {}
if File.exist?(HELD_PATH)
  File.foreach(HELD_PATH).with_index(1) do |ln, i|
    next if ln.start_with?("#") || ln.strip.empty?
    f = ln.chomp.split("\t", -1)
    f.length == 2 or abort("#{PROG}: #{HELD_PATH}:#{i}: #{f.length} column(s), want 2")
    f[1].strip.empty? and abort("#{PROG}: #{HELD_PATH}:#{i}: #{f[0]} needs a reason")
    held.key?(f[0]) and abort("#{PROG}: #{HELD_PATH}:#{i}: #{f[0]} is listed twice")
    held[f[0]] = f[1]
  end
end

schema = []
access = []
prepared = []
underived = 0
carried = 0
setup_carried = 0
held_used = []
scratch_underived = 0
nonliteral = 0
names = {}
folded = []
aliased = []
rows.each do |r|
  next unless r["disposition"] == "stored" || r["disposition"] == "prepared"
  name = flatten_name(r["class"], r["ivar"])
  # A REPRESENTATION replaces this row's shape but not its origin: the name,
  # element and count come from core-representations.tsv, and the origin column
  # below still says which ivar it stands for.
  rep = representations.delete("#{r['class']}@#{r['ivar']}")
  if rep && rep["fold"]
    folded << ["#{r['class']}@#{r['ivar']}", rep["fold"]]
    next
  end
  if rep && rep["alias"]
    aliased << [r, rep["alias"]]
    next
  end
  added_parts = representations.keys.select { |k| k.start_with?("#{r['class']}@#{r['ivar']}.") }
  name = rep["name"] if rep
  prior = names[name]
  prior and
    abort("#{PROG}: #{name} is the flattened name of both #{prior} and " \
          "#{r['class']}@#{r['ivar']}; names are globally unique and this does " \
          "not invent a suffix")
  names[name] = "#{r['class']}@#{r['ivar']}"

  # The element the DISPOSITION gives, not the reader's type: a byte buffer
  # the closure writes is u8 whether the reader called it a string or not.
  element = rep ? rep["element"] : r["stored-element"]
  ELEMENTS.include?(element) or
    abort("#{PROG}: #{r['class']}@#{r['ivar']} has element #{element.inspect}")
  count = rep ? rep["count"] : r["count"].split("|").first
  # THE FILL THE ALLOCATION USES, measured from the tree. Thirty allocations in
  # DOOM open at -1, and assuming zero made the schema claim an initial state
  # the game never has -- which the reference comparison is what found.
  fill = r["initial"]
  initial =
    case fill
    when /\A-?[0-9]+\z/ then fill
    when "FalseNode" then "0"
    when "TrueNode" then "1"
    when "UNDERIVED"
      # NOT THE SAME AS "not a literal". `UNDERIVED` means the audit found no
      # allocation to read a fill from at all. 0008 task 5 is about the state
      # just before the FIRST TICK, after Full initialisation, which is neither
      # an allocation fill nor a first assignment -- and 0008 has Full allocate
      # and initialise every buffer.
      #
      # SO A STORED ONE IS CARRIED BY FULL: `prepared:NAME`, its value read off
      # the objects Full constructs, its role and disposition unchanged -- it
      # stays mutable stored state; only where its opening value comes from is
      # declared. This used to write an assumed 0. Routing these to `prepared:`
      # was once refused because prepared data was then zeros on both sides and
      # left out of the comparison, which shrank what was compared; every
      # prepared field is now produced by Full and compared against the
      # reference by field and index, so the cells stay compared.
      #
      # The rule is the audit's shape, not a comparison result: nothing here
      # looks at whether an assumed 0 happened to agree.
      #
      # Two exceptions, both named. A SCRATCH field keeps 0: scratch is not in
      # the snapshot, and state.sh checks that the original holds no pre-tick
      # value for each one rather than taking the role as the reason. A field
      # in core-initials-held.tsv keeps 0 with its reason there, and that 0 is
      # not a claim about the original.
      underived += 1
      key = "#{r['class']}@#{r['ivar']}"
      if r["disposition"] == "prepared"
        "0"   # prepared below, as every prepared value is
      elsif r["role"] == "scratch"
        scratch_underived += 1
        "0"
      elsif held.key?(key)
        held_used << key
        "0"
      else
        carried += 1
        nil
      end
    else
      nonliteral += 1
      nil        # not a literal: Full has the value at construction
    end
  # WHAT A FILL `initial` DOES AND DOES NOT SAY. It is the fill the allocation
  # uses, measured from the tree. It is NOT the state the game opens in when
  # setup writes the field again: `Game.new` spawns the map's things, builds the
  # blocklinks and seeds the slot lists after allocating them, and none of that
  # is a fill.
  #
  # SO A STORED FIELD SETUP WRITES IS CARRIED BY FULL, like an UNDERIVED one:
  # `prepared:NAME`, role and disposition unchanged. Which fields those are is
  # the audit's setup walk (`--setup-writes`), a static fact about the tree --
  # not whether the fill happened to agree with the original, which would be
  # fitting the schema to the measurement. A field setup does not write keeps
  # its fill, and that fill is then the pre-tick state for this setup.
  key = "#{r['class']}@#{r['ivar']}"
  if initial && fill != "UNDERIVED" && r["disposition"] == "stored" &&
     r["role"] != "scratch" && setup_writes.key?(key)
    if held.key?(key)
      held_used << key
    else
      setup_carried += 1
      initial = nil
    end
  end
  # A PREPARED NAME BELONGS TO ONE FIELD, so it is the FIELD's name.
  #
  # It used to be the COUNT's catalog entry whenever the count named one, on
  # the reasoning that the declared count and the prepared length should be
  # one number stated once. The LENGTH still is -- it is resolved from the
  # count below -- but the NAME cannot be shared, because `Session.open` maps
  # a prepared name to one buffer and cannot hold two answers.
  #
  # Measured: `level_sector_validcount` and `renderer_sector_validcount` both
  # take their length from `numsectors`, so both declared `prepared:numsectors`
  # and both received the same bytes, while the originals open at 0 and at -1.
  # One of them was always wrong. Nothing saw it while prepared data was zeros
  # on both sides and prepared fields were left out of the comparison;
  # connecting real prepared data is what surfaced it.
  if initial.nil? || r["disposition"] == "prepared"
    initial = "prepared:#{name}"
    kind, _, cname = count.partition(":")
    len = kind == "fixed" ? cname : catalog_counts[cname]
    len or abort("#{PROG}: #{name}: no length for a prepared field with count #{count.inspect}")
    prepared << [name, len]
  end
  role = r["role"]
  # A prepared value is a `resource` whatever its accesses looked like: Full
  # has it before play and CORE does not write it.
  role = "resource" if r["disposition"] == "prepared"
  schema << [name, role, element, count, initial,
             "#{r['class']}@#{r['ivar']}", r["writers"]]
  added_parts.each do |part_key|
    part = representations.delete(part_key)
    names[part["name"]] and abort("#{PROG}: #{part['name']} is already a field")
    names[part["name"]] = part_key
    part_initial = initial.start_with?("prepared:") ? "prepared:#{part['name']}" : initial
    if part_initial.start_with?("prepared:")
      kind, _, cname = part["count"].partition(":")
      plen = kind == "fixed" ? cname : catalog_counts[cname]
      plen or abort("#{PROG}: #{part['name']}: no length for count #{part['count'].inspect}")
      prepared << [part["name"], plen]
    end
    schema << [part["name"], role, part["element"], part["count"], part_initial, part_key, r["writers"]]
    r["domains"].split(",").each do |d|
      entry = ENTRY_OF[d]
      next unless entry
      writes = !r["writers"].nil? && r["writers"] != "-" && role != "resource"
      access << [entry, part["name"], writes ? "inout" : "in"]
    end
  end

  # Which entries touch it, and how. `writers` names the owning subsystem;
  # `domains` names the entries that reach it, which is what decides whether a
  # buffer appears in an entry's list at all.
  r["domains"].split(",").each do |d|
    entry = ENTRY_OF[d]
    next unless entry
    writes = !r["writers"].nil? && r["writers"] != "-" && role != "resource"
    access << [entry, name, writes ? "inout" : "in"]
  end
end

# FIELDS NO IVAR HOLDS (tools/doom/core-added.tsv): a traversal stack, a
# capacity cell, the command buffer -- storage the port needs where the original
# needed none. Each is emitted with origin `added:KEY` and initial 0; a hand-off
# row adds only an access row for a field the schema already has, and its reason
# is carried into access.tsv as a `#handoff` line.
ADDED_PATH = opt[:added] || File.join(__dir__, "core-added.tsv")
File.exist?(ADDED_PATH) or abort("#{PROG}: no added-field table at #{ADDED_PATH}")
handoffs = []
added_n = 0
File.foreach(ADDED_PATH).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  f.length == 7 or abort("#{PROG}: #{ADDED_PATH}:#{i}: #{f.length} column(s), want 7")
  key, nm, role, el, cnt, ents, why = f
  why.strip.empty? and abort("#{PROG}: #{ADDED_PATH}:#{i}: #{nm} needs a reason")
  modes = ents.split(",").map { |e| e.split(":", 2) }
  modes.empty? and abort("#{PROG}: #{ADDED_PATH}:#{i}: #{nm} names no entry")
  modes.each do |d, m|
    (ENTRY_OF.key?(d) && %w[in inout].include?(m)) or
      abort("#{PROG}: #{ADDED_PATH}:#{i}: #{d}:#{m} is not ENTRY:in or ENTRY:inout")
  end
  if key == "handoff"
    (role == "-" && el == "-" && cnt == "-") or
      abort("#{PROG}: #{ADDED_PATH}:#{i}: a hand-off adds no field, so it has no role, element or count")
    names.key?(nm) or abort("#{PROG}: #{ADDED_PATH}:#{i}: #{nm} is handed off, and the schema does not have it")
    modes.each do |d, m|
      access.any? { |a| a[0] == ENTRY_OF[d] && a[1] == nm } and
        abort("#{PROG}: #{ADDED_PATH}:#{i}: #{ENTRY_OF[d]} already reaches #{nm}; a hand-off row would hide the measured one")
      access << [ENTRY_OF[d], nm, m]
      handoffs << [ENTRY_OF[d], nm, why]
    end
    next
  end
  key =~ /\A[a-z0-9-]+\z/ or abort("#{PROG}: #{ADDED_PATH}:#{i}: key #{key.inspect}")
  names.key?(nm) and abort("#{PROG}: #{ADDED_PATH}:#{i}: #{nm} is already a field (#{names[nm]})")
  %w[persistent scratch].include?(role) or
    abort("#{PROG}: #{ADDED_PATH}:#{i}: an added field is persistent or scratch, not #{role.inspect}")
  ELEMENTS.include?(el) or abort("#{PROG}: #{ADDED_PATH}:#{i}: element #{el.inspect}")
  cnt =~ /\A(fixed|level|screen|limit|table):/ or
    abort("#{PROG}: #{ADDED_PATH}:#{i}: count #{cnt.inspect} is not 0008's grammar")
  names[nm] = "added:#{key}"
  schema << [nm, role, el, cnt, "0", "added:#{key}", modes.select { |_, m| m == "inout" }.map { |d, _| ENTRY_OF[d] }.join(",")]
  modes.each { |d, m| access << [ENTRY_OF[d], nm, m] }
  added_n += 1
end

FileUtils.mkdir_p(File.dirname(opt[:schema]))
# A ROW THAT MATCHED NOTHING describes no field, and silently ignoring it would
# leave a replacement nobody can see was not made.
missing_folds = folded.flat_map { |_, ts| ts }.reject { |t| names.key?(t) }
missing_folds.empty? or abort("#{PROG}: a fold names #{missing_folds.join(', ')}, which the schema does not have")
# EACH ALIAS AGAINST ITS TARGET: the field exists, is not itself an alias's
# source, and has the ivar's element and count; the ivar's entries become the
# target's, with the target's mode where the target already has one and the
# ivar's own where it adds an entry.
aliases = []
aliased.each do |r, target|
  src = "#{r['class']}@#{r['ivar']}"
  row = schema.find { |x| x[0] == target } or
    abort("#{PROG}: #{src} is an alias of #{target}, which the schema does not have")
  element = r["stored-element"]
  count = r["count"].split("|").first
  (row[2] == element && row[3] == count) or
    abort("#{PROG}: #{src} is #{element} #{count} and its alias target #{target} is #{row[2]} #{row[3]}; " \
          "one storage has one shape")
  src_writes = !r["writers"].nil? && r["writers"] != "-"
  r["domains"].split(",").each do |d|
    entry = ENTRY_OF[d]
    next unless entry
    have = access.find { |a| a[0] == entry && a[1] == target }
    access << [entry, target, src_writes ? "inout" : "in"] unless have
    have[2] = "inout" if have && src_writes
  end
  # A TARGET NOTHING READ IS READ THROUGH ITS ALIAS. `output` says CORE writes a
  # field and does not read it back; the executor reading `jobs.sched_kind_bank`
  # as its own `@sc_kind` is that read. The target was allocated outside the
  # closure -- its initial is its allocation's fill -- so it outlives the call:
  # persistent. A target with no allocation fill is not decided here.
  if row[1] == "output" && !r["readers"].nil? && r["readers"] != "-"
    row[4] =~ /\A-?[0-9]+\z/ or
      abort("#{PROG}: #{src} reads #{target}, an output with no allocation fill; its role is not decided here")
    row[1] = "persistent"
  end
  aliases << [src, target, row[5]]
end
representations.empty? or
  abort("#{PROG}: #{representations.length} row(s) in #{File.basename(REP_PATH)} match no " \
        "inventory field: " + representations.keys.first(3).join(", "))
# The same for a held row: one that is not a stored UNDERIVED field holds nothing.
unheld = held.keys - held_used
unheld.empty? or
  abort("#{PROG}: #{unheld.length} row(s) in #{File.basename(HELD_PATH)} are not a stored, " \
        "non-scratch field Full would otherwise carry: " + unheld.first(3).join(", "))

# FIELDS NO SHIPPED CONFIGURATION WRITES (tools/doom/core-unreached.tsv): each
# row is carried into the schema as an `#unreached` line -- field,
# configuration, reason, gates -- so the field's status is declared where the
# field is, and no row, layout or offset moves. A row naming no schema field is
# refused.
UNREACHED_PATH = opt[:unreached] || File.join(__dir__, "core-unreached.tsv")
File.exist?(UNREACHED_PATH) or abort("#{PROG}: no unreached table at #{UNREACHED_PATH}")
schema_names = schema.map(&:first).to_set
unreached = []
File.foreach(UNREACHED_PATH).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  f.length == 4 or abort("#{PROG}: #{UNREACHED_PATH}:#{i}: #{f.length} column(s), want 4")
  f.any? { |c| c.strip.empty? } and abort("#{PROG}: #{UNREACHED_PATH}:#{i}: an empty column")
  schema_names.include?(f[0]) or abort("#{PROG}: #{UNREACHED_PATH}:#{i}: #{f[0]} is not a field of the schema")
  unreached.map(&:first).include?(f[0]) and abort("#{PROG}: #{UNREACHED_PATH}:#{i}: #{f[0]} is listed twice")
  unreached << f
end
unreached.sort!

# THE ELEMENT DECISION 0018 CHOSE, from examples/doom/core/widths.tsv
# (tools/doom/core-widths.rb). Everything above -- the representations, the
# folds, the aliases, each against its target -- is decided at the element the
# audit's disposition gives; the table then narrows the buffers the entries
# take, after all of that, so an alias and its target are compared as the
# storage they share and not as one narrowed and one not. Each row must name a
# field of the schema, and an element NO WIDER than the disposition's: the
# table narrows what the audit decided and never widens it.
widths_path = opt[:widths] || File.expand_path("../../examples/doom/core/widths.tsv", __dir__)
File.exist?(widths_path) or abort("#{PROG}: no width table at #{widths_path}")
narrowed = 0
File.foreach(widths_path).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  f.length == 6 or abort("#{PROG}: #{widths_path}:#{i}: #{f.length} column(s), want 6")
  nm, el = f
  ELEMENTS.include?(el) or abort("#{PROG}: #{widths_path}:#{i}: element #{el.inspect}")
  row = schema.find { |x| x[0] == nm } or abort("#{PROG}: #{widths_path}:#{i}: #{nm} is not a field of the schema")
  WIDTH.fetch(el) <= WIDTH.fetch(row[2]) or
    abort("#{PROG}: #{widths_path}:#{i}: #{nm} is #{row[2]} and the table would widen it to #{el}")
  narrowed += 1 unless row[2] == el
  row[2] = el
end

File.open(opt[:schema], "w") do |io|
  io.puts("# examples/doom/core/state.tsv -- GENERATED by tools/doom/emit-schema.rb")
  io.puts("# from the audit's state-use inventory. Do not edit: a field that moves")
  io.puts("# in the source moves here, and tools/doom/audit-core.rb is what decides")
  io.puts("# whether the move is allowed.")
  io.puts("#")
  io.puts("#name\trole\telement\tcount\tinitial\torigin\twriters")
  schema.sort_by { |r| r[0] }.each { |r| io.puts(r.join("\t")) }
  # The ivars that are one of the fields above, and not allocations of their own.
  aliases.sort.each { |src, target, origin| io.puts("#alias\t#{src}\t#{target}\t#{origin}") }
  unreached.each { |r| io.puts("#unreached\t#{r.join("\t")}") }
end
File.open(opt[:access], "w") do |io|
  io.puts("# examples/doom/core/access.tsv -- GENERATED by tools/doom/emit-schema.rb")
  io.puts("# Each participating buffer once per entry, with the mode the audit's")
  io.puts("# measured accesses give it.")
  io.puts("#")
  io.puts("#entry\tbuffer\tmode")
  access.uniq.sort.each { |r| io.puts(r.join("\t")) }
  # The rows above that are call arguments in the loop, not reads the audit measured.
  handoffs.sort.each { |r| io.puts("#handoff\t#{r.join("\t")}") }
end
if opt[:prepared]
  File.open(opt[:prepared], "w") do |io|
    io.puts("# examples/doom/core/prepared.tsv -- GENERATED by tools/doom/emit-schema.rb")
    io.puts("# The prepared values whose length the catalog does not already give, as")
    io.puts("# catalog rows. WHAT THIS CHECKS AND WHAT IT DOES NOT: these lengths come")
    io.puts("# from the same measurement the schema's counts did, so agreeing with the")
    io.puts("# schema does not independently confirm them. What it does catch is a")
    io.puts("# schema edited by hand, and Full arriving at a session with data of a")
    io.puts("# length the schema never declared.")
    io.puts("#")
    io.puts("#kind\tname\tvalue")
    prepared.uniq.sort.each { |n, v| io.puts("prepared\t#{n}\t#{v}") }
  end
end
warn("#{PROG}: initials #{schema.length - underived - nonliteral} from an allocation fill, " \
     "#{nonliteral} from a non-literal expression, #{underived} UNDERIVED")
fill_of = rows.to_h { |r| ["#{r['class']}@#{r['ivar']}", r["initial"]] }
underived_held = held_used.count { |k| fill_of[k] == "UNDERIVED" }
warn("#{PROG}: carried by Full as prepared: #{carried} stored UNDERIVED, #{setup_carried} stored " \
     "fields setup writes after allocating; #{scratch_underived} UNDERIVED scratch; " \
     "#{held_used.length} held (#{underived_held} UNDERIVED)")
warn("#{PROG}: #{schema.length} field(s) -> #{opt[:schema]}, " \
     "#{access.uniq.length} access row(s) -> #{opt[:access]}, #{aliases.length} alias(es), " \
     "#{added_n} added field(s), #{handoffs.length} hand-off row(s), #{narrowed} element(s) narrowed by #{File.basename(widths_path)}" +
     (opt[:prepared] ? ", #{prepared.uniq.length} prepared row(s) -> #{opt[:prepared]}" : ""))
