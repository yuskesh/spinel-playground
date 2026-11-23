# frozen_string_literal: true
#
# tools/doom/migration-ledger.rb — decision 0008 task 6's call-site inventory.
#
#   ruby tools/doom/migration-ledger.rb --closure FILE --entry NAME
#                                       --packed FILE --output FILE
#
# 0008 task 6: "Include a call-site inventory proving every original tick edge
# was migrated." This is that proof, and it is a comparison rather than a
# claim: the ORIGINAL edges come from the audit's measured closure, the
# MIGRATED definitions come from the packed CORE source as the contract reader
# reads it, and the ledger is the join.
#
# WHAT COUNTS AS MIGRATED. A row in tools/doom/core-migrated.tsv naming the
# original and the CORE definitions that replace it -- and every one of those
# definitions must exist in the packed source, which the reader's `methods`
# face is what says.
#
# NOT A NAME MATCH. The port renames: `Game#add_thinker` becomes
# `dc_take_slot` and `dc_link_slot`, and two unrelated names coinciding would
# otherwise read as a migration. Measured: matching by name alone called two
# of the tick's 238 definitions migrated when neither had been touched.
#
# WHAT IS NOT AN EDGE TO MIGRATE. A builtin -- an operator, or a callee with
# no definition in the tree -- is answered by tools/doom/core-builtins.tsv and
# is not a definition anyone could move. Those rows are counted separately so
# the denominator is the edges that CAN be migrated, and the file says which
# they are rather than quietly leaving them out.
#
# WHAT "MIGRATED" DOES NOT PROVE, stated because Mac review of 33da4d9 found
# this exact hole. A row is a NAME MAPPING plus a check that each named
# replacement EXISTS in the packed source. It does not prove that the named
# replacements, together, do what the original did.
#
# The worked example is `Game#add_thinker`. Its row named `dc_take_slot` and
# `dc_link_slot`, both of which existed, so the ledger called it migrated --
# but the original also STORES the function and its data between those two
# steps, and that store existed nowhere in CORE source. It lived in
# tests/doom-core/slot-model.rb's own `port_add`, so the comparison passed
# with the test supplying a step of the algorithm it was checking. The row now
# names `dc_store_thinker` too, and that definition is in the unit.
#
# NOTHING HERE WOULD HAVE CAUGHT THAT, and nothing here catches the next one:
# checking that a set of definitions reproduces an operation is what the
# comparison models are for, and the ledger cannot stand in for them. Two
# things follow, and they are not automated:
#
#   * A ROW IS NOT EVIDENCE. It is a claim that a comparison somewhere else
#     has been run. Where that comparison is should be in the row's note.
#   * A HELPER IS NOT AN OPERATION. `dc_take_slot` is a step; the operation is
#     `dc_add_thinker`, an entry with a contract, which reports a full arena as
#     the public CAPACITY status rather than a -1 nobody reads. Counting steps
#     as migrated operations overstates what has moved.
#
# EACH ROW COUNTS ONE FACT ABOUT ITSELF. An absorbed accessor is absorbed per
# entry, and a PARTIAL row names the paths remaining in that definition, not the
# work remaining in the feature: work another definition still needs is that
# definition's row, so it is never counted twice.
#
# The ledger does not decide when the migration is DONE; it says what remains,
# by name, so the claim "every tick edge was migrated" can be checked instead
# of repeated -- and "migrated" means "named and present", not "proved".
#
# EVERY DEFINITION THE ENTRY REACHES IS IN EXACTLY ONE STATE, and the states sum
# to the denominator (checked below). Each state is a claim, and each claim is
# what the verifier has to check for the definitions in it:
#
#   migrated    the named CORE definitions agree with the original on every
#               path a shipped configuration runs; a path only an unshipped
#               configuration runs is named on the row as
#               `unreached-path:CONFIG:NAME`, and is claimed unreached, not agreed.
#               A path the port no longer takes in its copy of the definition,
#               because the port reaches the original's path by another CORE
#               definition, is named `restructured-path:NAME:DEF`: the claim is
#               that the original's path NAME is reached, on every shipped run,
#               through DEF (a replacement named on the same row), that DEF is
#               what the verifier compares for it, and that the copy's own path
#               is dead -- not that the copy's path agrees.
#               A definition, or a path of one, that the SHIPPED CONTENT never
#               reaches is named `absent-in-content:CONTENT:REASON`, REASON one
#               of: things=N+... (no level places, and the original spawns, a
#               type whose state graph reaches the definition's action),
#               sector=N (no level has sector special N, which alone makes the
#               thinker the definition runs), sprite=NAME and gettable-unlisted
#               (no level places, and the original spawns, a pickup of that
#               sprite, or one the definition has no case for). One the original
#               reaches with NO content is named
#               `unreached-by-construction:thinker=TH_NAME`: nothing creates
#               the thinker kind that runs the definition. A path Full refuses
#               to call the entry for is named `guarded-by-full:NAME` (NAME
#               `rebirth`: Session#before_step! refuses a pending rebirth, and
#               the definition's own refusal is a backstop the shipped program
#               does not reach); tests/doom-core/refusals.rb and the scenario it
#               names check that Full refuses first.
#               These five reasons -- a configuration, the content, the
#               original's construction, a restructuring, a Full precondition --
#               are kept apart on purpose: each is checked by a different thing
#               and fails when a different thing changes. Both are claims that the code is not
#               compared because it cannot run, checked by
#               tests/doom-core/content-scan.rb -- not claims that it agrees.
#   absorbed    the accessor is gone: every caller in this entry is moved, and
#               they read the named resident fields instead of calling it.
#   absorbing   (to go) as absorbed, but a caller in this entry has not moved.
#   partial     the named CORE definitions agree with the original on every path
#               except the `remaining:NAME` paths, and only those remain.
#   eliminated  the definition's only effect is on storage the schema
#               eliminates (`eliminated:NAME`, the audit's disposition), which
#               nothing CORE computes reads.
#   unreached   no shipped configuration reaches the definition: every call to
#               it sits under the gate its configuration names in
#               tools/doom/core-unreached.tsv's configurations.
#   todo        nothing is claimed; the definition is still to move.
#
# A CONFIGURATION is a value no shipped program sets: `trace` (the renderer's
# column/wall/span record) and `jobs` (job modes 1 and 2, the job list and its
# executor, which the native program does not run: it renders in job mode 0,
# the owner's decision of 2026-10-21 in decision 0008). A name here must be a
# configuration of tools/doom/core-unreached.tsv.

require "optparse"
require "set"
require "tmpdir"
require_relative "contract_reader"

PROG = "migration-ledger"
opt = { entry: "step" }
OptionParser.new do |o|
  o.on("--closure FILE") { |v| opt[:closure] = v }
  o.on("--entry NAME") { |v| opt[:entry] = v }
  o.on("--packed FILE") { |v| opt[:packed] = v }
  o.on("--reader PATH") { |v| opt[:reader] = v }
  o.on("--output FILE") { |v| opt[:output] = v }
  o.on("--migrated FILE") { |v| opt[:migrated] = v }
  o.on("--schema FILE") { |v| opt[:schema] = v }
  o.on("--unreached FILE") { |v| opt[:unreached] = v }
  o.on("--source DIR") { |v| opt[:source] = v }
end.parse!
opt[:closure] or abort("#{PROG}: --closure is required")
File.exist?(opt[:closure]) or abort("#{PROG}: no closure at #{opt[:closure]}")

READER = opt[:reader] ||
         File.join(__dir__, "..", "..", "tools", "contract", "build", "spinel-typedump")

# --- what the original tick calls ---------------------------------------------
COLS = %w[from edge callee file line origin receiver domain resolution].freeze
callers = Set.new
targets = Hash.new { |h, k| h[k] = 0 }
# callee -> the definitions of this entry that call it, for the absorbed rule
callers_of = Hash.new { |h, k| h[k] = Set.new }
# Every definition ANY entry reaches: the table is shared by the three entries,
# so a row is dead only when no entry reaches its original.
anywhere = Set.new
builtins = Hash.new { |h, k| h[k] = 0 }
header = nil
roots = Set.new
File.foreach(opt[:closure]) do |ln|
  next if (ln.start_with?("#") && !ln.start_with?("# root\t")) || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  if ln.start_with?("# root\t")
    roots << f[1] if f[2] == opt[:entry]
    anywhere << f[1]
    next
  end
  if header.nil?
    header = f
    header == COLS or
      abort("#{PROG}: the closure's columns are #{f.join(', ')}, and this reads #{COLS.join(', ')}")
    next
  end
  res = f[8].to_s
  anywhere << f[0]
  anywhere << res if res.include?("#") && !(res.start_with?("builtin") || res.start_with?("BUILTIN") || res.start_with?("BLOCK"))
  next unless f[7].to_s.split(",").include?(opt[:entry])
  callers << f[0]
  if res.start_with?("builtin") || res.start_with?("BUILTIN") || res.start_with?("BLOCK")
    builtins[f[2]] += 1
  elsif res.include?("#")
    targets[res] += 1
    callers_of[res] << f[0]
  end
end
callers.empty? and abort("#{PROG}: the closure has no #{opt[:entry]} edges")

# Every definition the entry's own walk reaches: the callers, plus everything
# they call. A definition that is only ever a caller still has to move.
# THE ROOTS COUNT TOO: a boundary setter (`Renderer#extralight=`) makes no call,
# so no edge names it, and it is still something the entry reaches.
roots.empty? and abort("#{PROG}: the closure names no root for #{opt[:entry]}; it predates the root lines")
original = callers | targets.keys.to_set | roots

# --- what the packed source defines -------------------------------------------
migrated = Set.new
if opt[:packed] && File.exist?(opt[:packed])
  File.executable?(READER) or abort("#{PROG}: no reader at #{READER}")
  Dir.mktmpdir("migration-ledger") do |w|
    raw = ContractReader.run_face(READER, opt[:packed], "methods", File.join(w, "l"))
    ContractReader.tsv(raw, "methods", 3).each { |f| migrated << f[1] }
  end
end

# ABSORBED ACCESSORS. An accessor such as `Level#sector_floorheight` is not
# replaced by a definition: once its callers are ported it is a read of a
# resident field. Its row says so with `field:NAME` entries, each of which must
# be a field of the schema, and it is counted as ABSORBED, apart from MIGRATED,
# so the denominator stays the definitions the entry reaches and the report says
# how many of the moved ones are fields rather than code. A row names fields or
# definitions, never both.
FIELD = "field:"
schema_fields = Set.new
schema_path = opt[:schema] || File.join(__dir__, "..", "..", "examples", "doom", "core", "state.tsv")
if File.exist?(schema_path)
  File.foreach(schema_path) do |ln|
    next if ln.start_with?("#") || ln.strip.empty?
    schema_fields << ln.split("\t", 2).first
  end
end
ABSORBED = Set.new
# UNREACHED IN A CONFIGURATION. A definition reached only under a flag no program
# sets -- `unreached-in-config:NAME` -- is not migrated and not to do: it is
# counted apart, with its reason, so the denominator still shows it. It becomes
# ordinary migration work the day a program sets the flag.
UNREACHED = "unreached-in-config:"
UNREACHED_ROWS = Set.new
# PARTIAL IS NOT MIGRATED. A definition ported for some of its paths -- the
# walls' column and not the fuzz dispatch, the lenient check and not its strict
# raises -- names its replacements AND each path still to move, as
# `remaining:NAME`. It is counted apart, so `migrated` means every path, and it
# becomes migrated only when a row stops naming a remaining path. A note that
# begins with PARTIAL must name one, and a row that names one must say PARTIAL:
# nothing about "partial" says when it ends, so the ledger keeps asking.
REMAINING = "remaining:"
PARTIAL_ROWS = Set.new
# A PATH UNREACHED IN A CONFIGURATION: a migrated (or partial) definition whose
# body has a path only an unshipped configuration runs names it as
# `unreached-path:CONFIG:NAME`. It is neither a replacement nor a remaining path.
UNREACHED_PATH = "unreached-path:"
# A PATH RESTRUCTURED AWAY: `restructured-path:NAME:DEF` (see the header). DEF
# must be one of the row's own replacements, so the route that is compared is
# named where the dead path is.
RESTRUCTURED_PATH = "restructured-path:"
RESTRUCTURED_PATHS = Hash.new { |h, k| h[k] = [] }
# CODE THE SHIPPED CONTENT, OR ANY CONTENT, NEVER RUNS (see the header). The
# ledger checks the spelling; tests/doom-core/content-scan.rb checks the claim.
ABSENT = "absent-in-content:"
BY_CONSTRUCTION = "unreached-by-construction:"
BY_FULL = "guarded-by-full:"
UNRUNNABLE = Hash.new { |h, k| h[k] = [] }
ELIMINATED = "eliminated:"
ELIMINATED_ROWS = Set.new
unreached_path = opt[:unreached] || File.join(__dir__, "core-unreached.tsv")
File.exist?(unreached_path) or abort("#{PROG}: no configuration table at #{unreached_path}")
CONFIGS = File.readlines(unreached_path).reject { |l| l.start_with?("#") || l.strip.empty? }
              .map { |l| l.split("\t")[1].to_s.strip }.reject(&:empty?).to_set
UNREACHED_PATHS = Hash.new { |h, k| h[k] = [] }
# EACH CONFIGURATION'S GATE, AS THE ORIGINAL SPELLS IT. A path is unreached in a
# configuration only if the original tests this gate around it: the ledger
# reads the original's definitions (--source, the library the audit reads) and
# requires every definition this entry reaches whose body tests a gate to be
# unreached as a whole, or to name at least one unreached path of that
# configuration -- `unreached-path:CONFIG:empty` when the gated alternative does
# nothing -- and every row naming one to test that gate. A gate nobody
# classified is refused, not assumed.
# A gate belongs to the classes named: the renderer's `@trace` record and
# `Random`'s comparison log are both off in every shipped program.
CONFIG_GATE = { "trace" => [%w[Renderer Random], /@trace\b/], "jobs" => [%w[Renderer], /@jobmode\b/] }.freeze
(CONFIGS.to_a - CONFIG_GATE.keys).empty? or
  abort("#{PROG}: #{unreached_path} names configuration(s) with no gate here: #{(CONFIGS.to_a - CONFIG_GATE.keys).join(', ')}")

# The migration table: original -> the CORE definitions that replace it.
MIGRATED = {}
missing_target = []
if opt[:migrated] && File.exist?(opt[:migrated])
  File.foreach(opt[:migrated]).with_index(1) do |ln, i|
    next if ln.start_with?("#") || ln.strip.empty?
    f = ln.chomp.split("\t", -1)
    f.length == 3 or abort("#{PROG}: #{opt[:migrated]}:#{i}: #{f.length} column(s), want 3")
    orig, into, why = f
    why.strip.empty? and abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} needs a note")
    MIGRATED.key?(orig) and abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} is listed twice")
    names = into.split(",").map(&:strip).reject(&:empty?)
    remaining = names.select { |n| n.start_with?(REMAINING) }
    names -= remaining
    upaths = names.select { |n| n.start_with?(UNREACHED_PATH) }
    names -= upaths
    rpaths = names.select { |n| n.start_with?(RESTRUCTURED_PATH) }
    names -= rpaths
    unrun = names.select { |n| n.start_with?(ABSENT, BY_CONSTRUCTION, BY_FULL) }
    names -= unrun
    unrun.each do |u|
      ok = u =~ /\Aabsent-in-content:[a-z0-9]+:(things=\d+(\+\d+)*|sector=\d+|sprite=[A-Z0-9]{4}|gettable-unlisted)\z/ ||
           u =~ /\Aunreached-by-construction:thinker=TH_[A-Z_]+\z/ ||
           u =~ /\Aguarded-by-full:rebirth\z/
      ok or abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} names #{u}, which is not a content or construction claim this reads")
      UNRUNNABLE[orig] << u
    end
    rpaths.each do |r|
      path, route = r.delete_prefix(RESTRUCTURED_PATH).split(":", 2)
      path.to_s.empty? || route.to_s.empty? and
        abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} names #{r}; want restructured-path:NAME:DEF")
      names.include?(route) or
        abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} names #{r}, and #{route} is not a replacement on its row")
      RESTRUCTURED_PATHS[orig] << r
    end
    rpaths += unrun
    upaths.each do |u|
      cfg, path = u.delete_prefix(UNREACHED_PATH).split(":", 2)
      CONFIGS.include?(cfg) or
        abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} names #{u}; #{cfg.inspect} is not a configuration of #{unreached_path}")
      path.to_s.empty? and abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} names #{u} with no path name")
      UNREACHED_PATHS[orig] << u
    end
    names.each do |n|
      next unless n.start_with?(UNREACHED)
      CONFIGS.include?(n.delete_prefix(UNREACHED)) or
        abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} names #{n}, and that is not a configuration of #{unreached_path}")
    end
    names.empty? and abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} names no replacement")
    says_partial = why.lstrip.start_with?("PARTIAL")
    if says_partial && remaining.empty?
      abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} is PARTIAL and names no remaining path " \
            "(add remaining:NAME for each path still to move)")
    end
    if !says_partial && !remaining.empty?
      abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} names #{remaining.join(', ')} and its note does not " \
            "begin with PARTIAL")
    end
    remaining.any? { |n| n == REMAINING } and
      abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} has a remaining: entry with no path name")
    # A PARTIAL ROW NAMES THE PATHS REMAINING IN THAT DEFINITION, NOT THE WORK
    # REMAINING IN THE FEATURE: work that belongs to another definition is
    # counted by that definition's row, and naming it here would count it twice.
    # That a label is a path of this definition's own body is not checked -- a
    # label is not a code site -- but a label that names a definition is refused.
    remaining.select { |n| n.delete_prefix(REMAINING).include?("#") }.each do |n|
      abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} names #{n}, a definition; its remaining work is " \
            "counted by its own row")
    end
    unless remaining.empty?
      names.any? { |n| n.start_with?(FIELD, UNREACHED) } and
        abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} is partial and names a field or an unreached flag")
      PARTIAL_ROWS << orig
    end
    if names.any? { |n| n.start_with?(ELIMINATED) }
      names.all? { |n| n.start_with?(ELIMINATED) } && upaths.empty? && rpaths.empty? or
        abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} is eliminated and names something else too")
      names.each do |n|
        schema_fields.include?(n.delete_prefix(ELIMINATED)) and
          abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} names #{n}, and the schema keeps that field")
      end
      ELIMINATED_ROWS << orig
      MIGRATED[orig] = names
      next
    end
    if names.any? { |n| n.start_with?(UNREACHED) }
      upaths.empty? && rpaths.empty? or
        abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} is unreached as a whole and also names paths")
      names.length == 1 or
        abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} is unreached in a configuration and names something else too")
      UNREACHED_ROWS << orig
      MIGRATED[orig] = names
      next
    end
    fields = names.select { |n| n.start_with?(FIELD) }
    unless fields.empty? || fields.length == names.length
      abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} names both fields and definitions; an accessor is " \
            "absorbed into fields, a definition is replaced by definitions")
    end
    absent = if fields.empty?
               names.reject { |n| migrated.include?(n) }
             else
               fields.map { |n| n.delete_prefix(FIELD) }.reject { |n| schema_fields.include?(n) }
                     .map { |n| "#{FIELD}#{n} (not a field of #{schema_path})" }
             end
    missing_target << "#{orig} -> #{absent.join(', ')}" unless absent.empty?
    ABSORBED << orig unless fields.empty?
    (upaths + rpaths).empty? || fields.empty? or
      abort("#{PROG}: #{opt[:migrated]}:#{i}: #{orig} is absorbed into fields and names paths")
    MIGRATED[orig] = names + remaining + upaths + rpaths
  end
end
dead_rows = MIGRATED.keys.reject { |k| anywhere.include?(k) }

# AN ACCESSOR IS ABSORBED BY AN ENTRY ONLY WHEN NOTHING OF THAT ENTRY STILL CALLS
# IT. Its row says what it becomes once its callers read the field; while any
# caller in this entry is still to do, the accessor is still needed there and
# counts as to do, reported apart as waiting. So an accessor the render entry
# reads through ported code and step code still writes through is absorbed for
# neither until each entry's own callers have moved.
# A partial caller still calls on the paths it has not moved, so it has not moved.
moved = lambda do |c|
  (MIGRATED.key?(c) && !ABSORBED.include?(c) && !PARTIAL_ROWS.include?(c)) || UNREACHED_ROWS.include?(c)
end
eliminated = original.select { |k| ELIMINATED_ROWS.include?(k) }
waiting = original.select { |k| ABSORBED.include?(k) && !callers_of[k].all? { |c| moved.(c) } }
done = original.select do |k|
  MIGRATED.key?(k) && !ABSORBED.include?(k) && !UNREACHED_ROWS.include?(k) && !PARTIAL_ROWS.include?(k) &&
    !ELIMINATED_ROWS.include?(k)
end
unreached = original.select { |k| UNREACHED_ROWS.include?(k) }
partial = original.select { |k| PARTIAL_ROWS.include?(k) }
remaining_paths = partial.sum { |k| MIGRATED[k].count { |n| n.start_with?(REMAINING) } }
absorbed = original.select { |k| ABSORBED.include?(k) } - waiting
todo = original.reject { |k| MIGRATED.key?(k) } + waiting
# THE GATES, READ FROM THE ORIGINAL.
gate_problems = []
source_dir = opt[:source] || File.join(__dir__, "..", "..", "examples", "doom", "lib", "doom")
bodies = {}
if Dir.exist?(source_dir)
  require "prism"
  Dir[File.join(source_dir, "*.rb")].sort.each do |f|
    walk = lambda do |n, scope|
      next unless n
      case n
      when Prism::ClassNode, Prism::ModuleNode
        scope = n.constant_path.slice.split("::").last
      when Prism::DefNode
        bodies["#{scope}##{n.name}"] = n.slice
      end
      n.child_nodes.compact.each { |c| walk.call(c, scope) }
    end
    walk.call(Prism.parse(File.read(f)).value, nil)
  end
end
bodies.empty? and abort("#{PROG}: no original definitions under #{source_dir}; the gates cannot be read")
original.each do |k|
  body = bodies[k] or next
  CONFIG_GATE.each do |cfg, (klasses, gate)|
    tested = klasses.any? { |c| k.start_with?("#{c}#") } && body.match?(gate)
    named = UNREACHED_PATHS.fetch(k, []).any? { |u| u.start_with?("#{UNREACHED_PATH}#{cfg}:") }
    whole = (MIGRATED[k] || []).include?("#{UNREACHED}#{cfg}")
    if tested && !named && !whole && MIGRATED.key?(k)
      gate_problems << "#{k} tests the #{cfg} gate and its row names no unreached-path:#{cfg}:NAME"
    end
    if named && !tested
      gate_problems << "#{k} names an unreached #{cfg} path and its body does not test the #{cfg} gate"
    end
  end
end
unless gate_problems.empty?
  gate_problems.each { |g| warn("#{PROG}: #{g}") }
  abort("#{PROG}: #{gate_problems.length} gate problem(s): a path is unreached only where the original gates it")
end

# EXACTLY ONE STATE EACH, summing to the denominator.
states = [done, absorbed, unreached, partial, eliminated, todo]
states.sum(&:length) == original.size && states.flatten.uniq.length == original.size or
  abort("#{PROG}: the states do not partition the #{original.size} definition(s): " \
        "#{states.map(&:length).join(' + ')} = #{states.sum(&:length)}")
upath_rows = (done + partial).select { |k| UNREACHED_PATHS.key?(k) }
rows = original.to_a.sort.map do |k|
  [k, if waiting.include?(k) then "absorbing"
      elsif ABSORBED.include?(k) then "absorbed"
      elsif UNREACHED_ROWS.include?(k) then "unreached"
      elsif ELIMINATED_ROWS.include?(k) then "eliminated"
      elsif PARTIAL_ROWS.include?(k) then "partial"
      elsif MIGRATED.key?(k) then "migrated"
      else "todo"
      end,
   (MIGRATED[k] || []).join(","), targets[k]]
end

if opt[:output]
  File.open(opt[:output], "w") do |io|
    io.puts("# #{PROG}: the #{opt[:entry]} entry's call-site inventory.")
    io.puts("# `state` is whether the packed CORE source defines this name.")
    io.puts("# `sites` is how many call sites in the original reach it.")
    io.puts("#original\tstate\tinto\tsites")
    rows.each { |r| io.puts(r.join("\t")) }
    io.puts("#builtins\t#{builtins.size} name(s), #{builtins.values.sum} site(s)")
  end
end

unless missing_target.empty?
  warn("#{PROG}: #{missing_target.length} row(s) name a replacement the packed source does not " \
       "define: #{missing_target.first(3).join('; ')}")
end
unless dead_rows.empty?
  warn("#{PROG}: #{dead_rows.length} row(s) name an original no entry reaches: " \
       "#{dead_rows.first(3).join(', ')}")
end
warn("#{PROG}: #{opt[:entry]}: #{original.size} definition(s) reachable, " \
     "#{done.length} migrated, #{absorbed.length} absorbed into fields, " \
     "#{unreached.length} unreached in a configuration, " \
     "#{partial.length} partial (#{remaining_paths} remaining path(s) named), #{todo.length} to go " \
     "(#{waiting.length} of them accessors whose field is ready and whose callers are not); " \
     "#{builtins.size} builtin name(s) over #{builtins.values.sum} site(s) are not definitions to move")
warn("#{PROG}: `migrated` means NAMED AND PRESENT in the packed source, not " \
     "proved equivalent -- see the header. " \
     "#{MIGRATED.values.sum { |v| v.count { |n| !n.start_with?(REMAINING, UNREACHED_PATH, RESTRUCTURED_PATH, ABSENT, BY_CONSTRUCTION, BY_FULL) } }} " \
     "replacement definition(s) across " \
     "#{done.length + absorbed.length + unreached.length + partial.length} row(s).")
warn("#{PROG}: #{opt[:entry]}: #{eliminated.length} definition(s) whose only effect is eliminated storage" \
     "#{eliminated.empty? ? '' : " (#{eliminated.sort.join(', ')})"}")
warn("#{PROG}: #{opt[:entry]}: #{upath_rows.length} moved definition(s) name " \
     "#{upath_rows.sum { |k| UNREACHED_PATHS[k].length }} path(s) unreached in a configuration" \
     "#{upath_rows.empty? ? '' : " (#{upath_rows.sort.join(', ')})"}")
rpath_rows = (done + partial).select { |k| RESTRUCTURED_PATHS.key?(k) }
warn("#{PROG}: #{opt[:entry]}: #{rpath_rows.length} moved definition(s) name " \
     "#{rpath_rows.sum { |k| RESTRUCTURED_PATHS[k].length }} path(s) reached through another definition" \
     "#{rpath_rows.empty? ? '' : " (#{rpath_rows.sort.map { |k| RESTRUCTURED_PATHS[k].join(' ') }.join(', ')})"}")
urun_rows = (done + partial).select { |k| UNRUNNABLE.key?(k) }
warn("#{PROG}: #{opt[:entry]}: #{urun_rows.length} moved definition(s) name " \
     "#{urun_rows.sum { |k| UNRUNNABLE[k].length }} part(s) the shipped program does not run" \
     "#{urun_rows.empty? ? '' : " (#{urun_rows.sort.join(', ')})"}")
exit(todo.empty? && missing_target.empty? && dead_rows.empty? ? 0 : 1)
