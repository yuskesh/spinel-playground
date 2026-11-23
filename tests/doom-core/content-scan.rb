# frozen_string_literal: true
#
# tests/doom-core/content-scan.rb — code no shipped content runs, checked.
#
#   ruby tests/doom-core/content-scan.rb [--lib DIR] [--planted-control] WAD [MIGRATED]
#
# tools/doom/migration-ledger.rb reads two claims off core-migrated.tsv rows and
# checks only their spelling; this checks what they say, against the IWAD and
# the original library (examples/doom/lib/doom):
#
#   absent-in-content:CONTENT:things=N+...
#       the doomednums whose state graph (spawn, see, pain, melee, missile,
#       death, xdeath, through nextstate) reaches the action the row's
#       definition performs are EXACTLY those listed; none is placed by any level
#       of the IWAD; and no spawn in the original makes one of those types
#   absent-in-content:CONTENT:sector=N
#       no sector of any level has special N, and the thinker the row's
#       definition runs is created only by definitions called under `when N`
#   absent-in-content:CONTENT:sprite=NAME
#       no level places a type whose spawn sprite is NAME
#   absent-in-content:CONTENT:gettable-unlisted
#       no level places a pickup (MF_SPECIAL) whose sprite Game#give_by_sprite
#       has no case for
#   unreached-by-construction:thinker=TH_NAME
#       nothing in the original creates a TH_NAME thinker
#
# CONTENT names the IWAD the claim is about; this refuses a claim about another.
# Prints one line per claim and `content-scan: N claim(s), all hold`, or a
# `refused ...` line per failure, exiting 1.
ROOT = File.expand_path("../..", __dir__)
# --lib DIR reads the original library from a copy: how a control plants a spawn
PLANTED = !ARGV.delete("--planted-control").nil?
LIB = (i = ARGV.index("--lib")) ? ARGV.slice!(i, 2).last : File.join(ROOT, "examples/doom/lib/doom")
require File.join(ROOT, "examples/doom/lib/doom", "wad")
require File.join(ROOT, "examples/doom/lib/doom", "info")
require "set"

wad_path, migrated = ARGV[0], ARGV[1] || File.join(ROOT, "tools/doom/core-migrated.tsv")
wad_path && File.exist?(wad_path) or abort("usage: content-scan.rb WAD [MIGRATED]")
CONTENT = File.basename(wad_path, ".wad").downcase
# THE IWAD IS THE ONE docs/doom.md PINS, by digest, not by its name.
# --planted-control accepts another -- a control's copy with one planted thing
# or sector -- and says so on its first line.
require "digest"
pinned = File.read(File.join(ROOT, "docs/doom.md"))[/`#{Regexp.escape(File.basename(wad_path))}`.*?SHA-256 `([0-9a-f]{64})`/, 1] or
  abort("content-scan: docs/doom.md pins no digest for #{File.basename(wad_path)}")
if PLANTED
  puts "content-scan: PLANTED CONTROL -- #{wad_path} is not checked against the pinned digest"
else
  Digest::SHA256.file(wad_path).hexdigest == pinned or
      abort("content-scan: #{wad_path} is not the pinned #{File.basename(wad_path)} (docs/doom.md SHA-256 #{pinned})")
end
I = Doom::Info
wad = Doom::Wad.new(wad_path)
errors = []
refuse = ->(m) { errors << "refused #{m}" }

# --- the content: every level of the IWAD ---------------------------------------
maps = (0...wad.count).map { |k| wad.lump(k).name }.grep(/\AE\dM\d\z|\AMAP\d\d\z/)
placed = Hash.new { |h, k| h[k] = [] }      # doomednum -> maps
sectors = Hash.new { |h, k| h[k] = [] }     # special -> maps
maps.each do |m|
  i = wad.index_of(m)
  names = (1..8).map { |d| wad.lump(i + d).name }
  names[0] == "THINGS" && names[7] == "SECTORS" or abort("content-scan: #{m}'s lumps are #{names.join(',')}")
  th = wad.bytes(i + 1)
  (th.bytesize / 10).times { |k| placed[th.byteslice(k * 10 + 6, 2).unpack1("S<")] |= [m] }
  se = wad.bytes(i + 8)
  (se.bytesize / 26).times { |k| sectors[se.byteslice(k * 26 + 22, 2).unpack1("s<")] |= [m] }
end
maps.empty? and abort("content-scan: #{wad_path} has no levels")

# --- the original library, parsed ----------------------------------------------
# Game and the modules it includes: the code the step entry ports.
require "prism"
GAME_FILES = %w[game.rb mapmove.rb specials.rb enemy.rb inter.rb pspr.rb sight.rb].freeze
src = GAME_FILES.to_h { |f| [f, File.read(File.join(LIB, f))] }
# every node with its chain of ancestors and the def it sits in
NODES = []
walk = lambda do |node, file, chain, df|
  return unless node
  df = node if node.is_a?(Prism::DefNode)
  NODES << [node, file, chain, df]
  node.compact_child_nodes.each { |c| walk.(c, file, chain + [node], df) }
end
src.each { |f, text| walk.(Prism.parse(text).value, f, [], nil) }
defs = NODES.select { |n, *| n.is_a?(Prism::DefNode) }.to_h { |n, f, *| [n.name.to_s, [n, f]] }
calls = NODES.select { |n, *| n.is_a?(Prism::CallNode) }
const_name = ->(n) { n.is_a?(Prism::ConstantReadNode) ? n.name.to_s : (n.is_a?(Prism::ConstantPathNode) ? n.slice.split("::").last : nil) }
params_of = ->(d) { d.parameters ? d.parameters.requireds.map { |x| x.name.to_s } : [] }
where = ->(n, f, df) { "#{f}:#{n.location.start_line}#{df ? " in #{df.name}" : ''}" }
dn = I.mobj_doomednum
spr = I.sprnames
sprite_of = ->(t) { spr[I.state_sprite[I.mobj_spawnstate[t]]] }
types_of = ->(dnums) { (0...dn.length).select { |t| dnums.include?(dn[t]) } }
entry = [I.mobj_spawnstate, I.mobj_seestate, I.mobj_painstate, I.mobj_meleestate, I.mobj_missilestate,
         I.mobj_deathstate, I.mobj_xdeathstate]
reaching = lambda do |a|
  (0...dn.length).select do |t|
    seen = {}
    q = entry.map { |c| c[t] }.select { |s| s && s > 0 }
    until q.empty?
      s = q.shift
      next if seen[s]
      seen[s] = true
      q << I.state_nextstate[s] if I.state_nextstate[s].to_i > 0
    end
    seen.keys.any? { |s| I.state_action[s] == a }
  end.map { |t| dn[t] }.uniq.sort
end
# which action a definition performs: the dispatch `when Info::ACT_X then name(...)`
ACTION_OF = src.values.join("\n").scan(/when Info::ACT_(\w+) then (\w+)\(/).to_h { |act, name| [name, I.const_get("ACT_#{act}")] }
constants = src.values.join("\n").scan(/\b([A-Z][A-Z0-9_]+) = (-?\d+)\b/).to_h { |n, v| [n, Integer(v, 10)] }
File.read(File.join(LIB, "defs.rb")).scan(/\b([A-Z][A-Z0-9_]+) = (-?\d+)\b/).each { |n, v| constants[n] ||= Integer(v, 10) }

# EVERY SPAWN, BY ITS TYPE ARGUMENT. A spawner is a definition with a `type`
# parameter; each call to one passes an MT_ constant, the calling spawner's own
# `type` (its callers are checked in turn), a local every write of which is an
# MT_ constant or type number, or -- spawn_map_thing and its callers -- the
# level's placement, which the content scan covers. Anything else is refused: a
# spawn this cannot read.
SPAWNERS = defs.select { |_, (d, _)| params_of.(d).include?("type") }.transform_values { |(d, _)| params_of.(d).index("type") }
PLACEMENT = %w[spawn_map_thing].freeze
spawned_types = Set.new
calls.each do |n, f, _chain, df|
  idx = SPAWNERS[n.name.to_s] or next
  arg = n.arguments&.arguments&.[](idx)
  at = where.(n, f, df)
  arg or (refuse.("#{at}: #{n.name} has no type argument"); next)
  # the level's own placement: the content scan covers what it spawns
  next if PLACEMENT.include?(n.name.to_s) || (df && PLACEMENT.include?(df.name.to_s))
  lit = ->(v) { (c = const_name.(v)) ? c : (v.is_a?(Prism::IntegerNode) ? v.value : nil) }
  names = if (c = const_name.(arg))
            [c]
          elsif arg.is_a?(Prism::IntegerNode)
            [arg.value]
          elsif arg.is_a?(Prism::LocalVariableReadNode) && df && params_of.(df).include?(arg.name.to_s)
            if arg.name.to_s == "type" && SPAWNERS.key?(df.name.to_s) then []
            elsif PLACEMENT.include?(df.name.to_s) then []
            else refuse.("#{at}: #{n.name}'s type is parameter #{arg.name} of #{df.name}"); []
            end
          elsif arg.is_a?(Prism::LocalVariableReadNode)
            ws = NODES.select { |w, _, _, d| d.equal?(df) && w.is_a?(Prism::LocalVariableWriteNode) && w.name == arg.name }
            vals = ws.map { |w, *| lit.(w.value) }
            (!ws.empty? && vals.none?(&:nil?)) or refuse.("#{at}: #{n.name}'s type #{arg.name} is written other than as a constant")
            vals.compact
          else
            refuse.("#{at}: #{n.name}'s type is a #{arg.class.name.split('::').last}, which this cannot read"); []
          end
  names.each do |nm|
    next spawned_types << nm if nm.is_a?(Integer)
    constants.key?(nm) or (refuse.("#{at}: #{n.name} spawns #{nm}, whose value this cannot read"); next)
    spawned_types << constants[nm]
  end
end
# EVERY THINKER CREATION: add_thinker's first argument, or a store into @th_func.
created = Hash.new { |h, k| h[k] = [] }   # TH name -> defs creating it
calls.each do |n, f, _chain, df|
  args = n.arguments&.arguments || []
  if n.name == :add_thinker
    c = const_name.(args[0])
    c ? created[c] << df&.name.to_s : refuse.("#{where.(n, f, df)}: add_thinker's kind is not a constant")
  elsif n.name == :[]= && n.receiver.is_a?(Prism::InstanceVariableReadNode) && n.receiver.name == :@th_func
    c = const_name.(args[1])
    next if c
    next if df && df.name == :add_thinker
    refuse.("#{where.(n, f, df)}: @th_func is stored other than as a constant, outside add_thinker")
  end
end
NODES.each do |n, f, _chain, df|
  next unless n.is_a?(Prism::CallNode) && n.name == :[]= && n.receiver.is_a?(Prism::InstanceVariableReadNode) &&
              n.receiver.name == :@th_func
  c = const_name.(n.arguments.arguments[1])
  created[c] << df&.name.to_s if c && c != "TH_REMOVED" && c != "TH_NULL"
end
# the definition each thinker kind runs: game.rb's `f == TH_X` dispatch
RUNS = src.fetch("game.rb").scan(/f == (TH_[A-Z_]+)\s*\n\s*(\w+)\(/).to_h
# give_by_sprite-style cases: `when "NAME"` inside a definition
cases_in = ->(name) { (d = defs[name]) ? d[0].slice.scan(/when "([A-Z0-9]{4})"/).flatten.to_set : Set.new }
# every call of a definition, with the `when` values it sits under
callers = ->(name) { calls.select { |n, *| n.name.to_s == name } }
# `when N` of a `case` on a sector's special: the case subject reads
# sector_special, or is a local written from it in the same definition
on_special = lambda do |subject, df|
  return true if subject.slice.include?("sector_special")
  return false unless subject.is_a?(Prism::LocalVariableReadNode) && df
  NODES.any? { |w, _, _, d| d.equal?(df) && w.is_a?(Prism::LocalVariableWriteNode) && w.name == subject.name && w.value.slice.include?("sector_special") }
end
under_when = lambda do |chain, n, df|
  chain.each_with_index.any? do |a, k|
    next false unless a.is_a?(Prism::WhenNode) && a.conditions.any? { |c| c.is_a?(Prism::IntegerNode) && c.value == n }
    cs = chain[0...k].reverse.find { |x| x.is_a?(Prism::CaseNode) }
    cs && cs.predicate && on_special.(cs.predicate, df)
  end
end

claims = 0
File.foreach(migrated).with_index(1) do |ln, lineno|
  next if ln.start_with?("#") || ln.strip.empty?
  orig, into, = ln.chomp.split("\t", -1)
  name = orig.split("#", 2)[1]
  into.split(",").map(&:strip).each do |tok|
    next unless tok.start_with?("absent-in-content:", "unreached-by-construction:")
    claims += 1
    at = "#{File.basename(migrated)}:#{lineno} #{orig} #{tok}"
    if tok.start_with?("unreached-by-construction:")
      th = tok[/thinker=(TH_[A-Z_]+)\z/, 1] or (refuse.("#{at}: not a claim this reads"); next)
      constants.key?(th) or (refuse.("#{at}: #{th} is no thinker kind the original defines"); next)
      RUNS[th] == name or (refuse.("#{at}: a #{th} thinker runs #{RUNS[th].inspect}, not #{name}"); next)
      created[th].empty? ? puts("content-scan: #{orig}: nothing creates #{th}, the kind that runs #{name}") :
                           refuse.("#{at}: #{created[th].uniq.join(', ')} create(s) #{th}")
      next
    end
    content, reason = tok.delete_prefix("absent-in-content:").split(":", 2)
    content == CONTENT or (refuse.("#{at}: a claim about #{content}, and this scans #{CONTENT}"); next)
    case reason
    when /\Athings=([\d+]+)\z/
      claimed = $1.split("+").map { |x| Integer(x, 10) }.sort
      act = ACTION_OF[name] or (refuse.("#{at}: #{name} is no action a dispatch names"); next)
      derived = reaching.(act)
      derived == claimed or refuse.("#{at}: the types reaching #{name} are #{derived.join(',')}, not #{claimed.join(',')}")
      present = claimed.select { |d| placed.key?(d) }
      present.each { |d| refuse.("#{at}: type #{d} is placed in #{placed[d].join(',')}") }
      made = types_of.(claimed).select { |t| spawned_types.include?(t) }
      made.each { |t| refuse.("#{at}: the original spawns type #{dn[t]}") }
      puts "content-scan: #{orig}: types #{claimed.join(',')} reach it, none placed in #{maps.length} level(s), none spawned" if present.empty? && made.empty? && derived == claimed
    when /\Asector=(\d+)\z/
      n = Integer($1, 10)
      sectors.key?(n) and refuse.("#{at}: sector special #{n} is in #{sectors[n].join(',')}")
      th = RUNS.key(name) or (refuse.("#{at}: no thinker kind runs #{name}"); next)
      makers = created[th].uniq
      makers.empty? and (refuse.("#{at}: nothing creates #{th}, so this is a construction claim, not a content one"); next)
      bad = makers.flat_map do |mk|
        cs = callers.(mk)
        cs.empty? ? ["#{mk} (never called)"] : cs.reject { |c, _, chain, cdf| under_when.(chain, n, cdf) }.map { |c, f, _, df| "#{mk} at #{where.(c, f, df)}" }
      end
      bad.each { |b| refuse.("#{at}: #{th} is made by #{b}, which is not under `when #{n}`") }
      puts "content-scan: #{orig}: #{th} (which runs #{name}) is made only under sector special #{n}, which no level has" if !sectors.key?(n) && bad.empty?
    when /\Asprite=([A-Z0-9]{4})\z/
      nm = $1
      cases_in.(name).include?(nm) or (refuse.("#{at}: #{name} has no case for sprite #{nm}"); next)
      types = (0...dn.length).select { |t| sprite_of.(t) == nm }.map { |t| dn[t] }
      types.empty? and (refuse.("#{at}: no type has the sprite #{nm}, so the claim is empty"); next)
      present = types.select { |d| placed.key?(d) }
      present.each { |d| refuse.("#{at}: type #{d} (sprite #{nm}) is placed in #{placed[d].join(',')}") }
      made = types_of.(types).select { |t| spawned_types.include?(t) }
      made.each { |t| refuse.("#{at}: the original spawns type #{dn[t]} (sprite #{nm})") }
      puts "content-scan: #{orig}: sprite #{nm} is types #{types.join(',')}, none placed or spawned" if present.empty? && made.empty?
    when "gettable-unlisted"
      cases = cases_in.(name)
      cases.empty? and (refuse.("#{at}: #{name} has no sprite cases, so it is not the gettable dispatch"); next)
      unlisted = (0...dn.length).select { |t| (I.mobj_flags[t] & I::MF_SPECIAL) != 0 && !cases.include?(sprite_of.(t)) }
      unlisted.empty? and (refuse.("#{at}: every pickup has a case, so the claim is empty"); next)
      present = unlisted.select { |t| placed.key?(dn[t]) }
      present.each { |t| refuse.("#{at}: type #{dn[t]} (sprite #{sprite_of.(t)}) has no case and is placed in #{placed[dn[t]].join(',')}") }
      made = unlisted.select { |t| spawned_types.include?(t) }
      made.each { |t| refuse.("#{at}: the original spawns type #{dn[t]}, which has no case") }
      puts "content-scan: #{orig}: pickups with no case are types #{unlisted.map { |t| dn[t] }.join(',')}, none placed or spawned" if present.empty? && made.empty?
    else
      refuse.("#{at}: not a reason this reads")
    end
  end
end
errors.each { |e| puts e }
puts "content-scan: #{claims} claim(s)#{errors.empty? ? ', all hold' : ", #{errors.length} refused"} over #{maps.length} level(s) of #{CONTENT}"
exit(errors.empty? && claims.positive? ? 0 : 1)
