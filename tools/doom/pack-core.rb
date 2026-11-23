# frozen_string_literal: true
#
# tools/doom/pack-core.rb — decision 0008 task 2's source packager.
#
#   ruby tools/doom/pack-core.rb --manifest FILE --root DIR \
#                                --output FILE --map FILE [--reader PATH] \
#                                [--entry NAME]
#
# ONE INTEGER WIDTH PER ENTRY (decision 0022 §2.6). A manifest may name each
# entry's width on a `#width<TAB>ENTRY<TAB>WIDTH` line, WIDTH `int64` or
# `target`. A manifest with such lines is packed for one entry at a time,
# given by --entry, and that entry's line decides the packed file's width:
#
#   int64   the file starts with `# spinel: int64`, written here when the
#           first unit does not declare it -- exactly what a manifest without
#           width lines gets when any unit declares it, so the bytes are the
#           same;
#   target  the file computes at the target's width, and a unit that still
#           declares `# spinel: int64` is refused (`width`): the declaration
#           would decide nothing, or, as the first unit's first line, move
#           the whole entry.
#
# ONE ENTRY'S UNITS. A `#units<TAB>ENTRY<TAB>a.rb,b.rb` line names the units
# that entry is packed from, in the manifest's order; without one an entry is
# packed from every unit. A 32-bit body refuses any top-level constant past
# 32 bits in its file, closure or not, so an entry that has moved is packed
# from its own units only: the others' wide tables are not its to carry. A
# unit named there must be a unit of the manifest, and the other units stay
# listed (they are not unlisted .rb files).
#
# Width is the manifest's, not the units': an entry that has not moved keeps
# int64 when the units it shares with a moved entry drop their declarations.
# A manifest without width lines is packed as before, the file int64 when any
# unit declares it, and --entry is refused for it.
#
# A CORE entry is compiled from one file. The sources it is maintained in are
# several, so they are packed into one, and the packing has to be the boring
# part: the same manifest over the same bytes must produce the same output
# byte for byte, and every line of the packed file must be traceable to the
# unit and offset it came from.
#
# READ ONCE. Each unit's bytes are read exactly once, and everything after
# that -- the digest check, the parse, the assembly, the map -- uses that one
# capture. A source edited while the packer runs cannot make the output
# disagree with the map, because no later step goes back to the file. The
# packer says so when it notices, and still emits what it captured.
#
# NEWLINE ONLY. Units are joined by nothing but a newline where one is
# missing. No banner, no `# line` directive, no blank padding: an inserted
# line is a line the map would have to account for and a byte the next run
# would have to reproduce.
#
# THE PARSER IS THE READER. Semantic questions -- what does this unit define,
# does it run anything at the top level, does it require another file -- are
# answered by the pinned contract reader through tools/doom/contract_reader.rb,
# which is the same parser the eligibility checker sees. No regex decides
# whether a Ruby definition is unconditional.
#
# EACH PARSE IS ITS OWN NAMESPACE. A unit's node 7 and the packed file's node 7
# are different nodes. Inventories are compared BY NAME; ids are never joined
# across parses.
#
# NOTHING IS REPLACED ON FAILURE. The output and the map are written to
# temporary files beside their destinations and renamed only after every check
# has passed, so a failed run leaves the previous package exactly as it was.

require "optparse"
require "digest"
require "fileutils"
require "set"
require "tmpdir"
require_relative "contract_reader"

PROG = "pack-core"

opt = {}
OptionParser.new do |o|
  o.on("--manifest FILE") { |v| opt[:manifest] = v }
  o.on("--root DIR") { |v| opt[:root] = v }
  o.on("--output FILE") { |v| opt[:output] = v }
  o.on("--map FILE") { |v| opt[:map] = v }
  o.on("--reader PATH") { |v| opt[:reader] = v }
  o.on("--entry NAME") { |v| opt[:entry] = v }
end.parse!

# Every refusal names its category, so a test can require the category rather
# than a sentence, and a new refusal cannot quietly reuse an old one's name.
CATEGORIES = %w[
  usage manifest width path-traversal outside-root missing-file digest unlisted-unit
  require-relative top-level-execution end-marker syntax encoding
  duplicate-definition inventory output
].freeze

def refuse(category, message, origin = nil)
  CATEGORIES.include?(category) or raise "unknown refusal category #{category.inspect}"
  where = origin ? "#{origin}: " : ""
  warn("#{PROG}: #{category}: #{where}#{message}")
  exit(1)
end

%i[manifest root output map].each do |k|
  refuse("usage", "--#{k} is required") unless opt[k]
end
ROOT = File.expand_path(opt[:root])
Dir.exist?(ROOT) or refuse("usage", "--root #{opt[:root]} is not a directory")
File.exist?(opt[:manifest]) or refuse("usage", "no manifest at #{opt[:manifest]}")

TOOLS = __dir__
READER = opt[:reader] || File.join(TOOLS, "..", "..", "tools", "contract", "build", "spinel-typedump")
File.executable?(READER) or refuse("usage", "no reader at #{READER}")

# --- the manifest -------------------------------------------------------------
# Two columns, `path` and `sha256`, and THE ORDER IS THE PACKING ORDER. A unit
# that comes second in the manifest comes second in the output; sorting it
# would make the output depend on a locale.
units = []
seen_paths = {}
widths = {}
width_lines = {} # entry -> the manifest line that gives its width
entry_units = {}
File.foreach(opt[:manifest]).with_index(1) do |ln, i|
  if ln.start_with?("#width\t")
    f = ln.chomp.split("\t", -1)
    origin = "#{opt[:manifest]}:#{i}"
    f.length == 3 or refuse("manifest", "a width line has #{f.length} column(s), want 3 (#width, entry, width)", origin)
    %w[int64 target].include?(f[2]) or refuse("manifest", "width #{f[2].inspect} is neither int64 nor target", origin)
    widths.key?(f[1]) and refuse("manifest", "#{f[1]}'s width is given twice", origin)
    widths[f[1]] = f[2]
    width_lines[f[1]] = i
    next
  end
  if ln.start_with?("#units\t")
    f = ln.chomp.split("\t", -1)
    origin = "#{opt[:manifest]}:#{i}"
    f.length == 3 or refuse("manifest", "a units line has #{f.length} column(s), want 3 (#units, entry, units)", origin)
    entry_units.key?(f[1]) and refuse("manifest", "#{f[1]}'s units are given twice", origin)
    entry_units[f[1]] = f[2].split(",")
    next
  end
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  origin = "#{opt[:manifest]}:#{i}"
  f.length == 2 or refuse("manifest", "#{f.length} column(s), want 2 (path, sha256)", origin)
  path, sha = f
  path.empty? and refuse("manifest", "empty path", origin)
  sha =~ /\A[0-9a-f]{64}\z/ or refuse("manifest", "#{sha.inspect} is not a sha256", origin)
  seen_paths[path] and
    refuse("manifest", "#{path} is listed twice, at line #{seen_paths[path]} and here", origin)
  seen_paths[path] = i
  path.start_with?("/") and refuse("path-traversal", "#{path} is absolute", origin)
  path.split("/").include?("..") and refuse("path-traversal", "#{path} climbs out with ..", origin)
  abs = File.expand_path(File.join(ROOT, path))
  unless abs == ROOT || abs.start_with?(ROOT + File::SEPARATOR)
    refuse("outside-root", "#{path} resolves to #{abs}, which is outside #{ROOT}", origin)
  end
  units << { "path" => path, "sha" => sha, "abs" => abs, "line" => i }
end
units.empty? and refuse("manifest", "the manifest lists no units")
if widths.empty?
  opt[:entry] and refuse("usage", "--entry #{opt[:entry]}, and #{opt[:manifest]} names no entry's width")
  width = nil
else
  opt[:entry] or refuse("usage", "#{opt[:manifest]} gives each entry its width: name the entry with --entry")
  width = widths[opt[:entry]] or refuse("width", "#{opt[:manifest]} gives no width for #{opt[:entry]}")
end
only = opt[:entry] && entry_units[opt[:entry]]
if only
  known = units.map { |u| u["path"] }
  (only - known).empty? or refuse("manifest", "#{opt[:entry]}'s units name #{(only - known).join(', ')}, which the manifest does not list")
  only.uniq.length == only.length or refuse("manifest", "#{opt[:entry]}'s units name a unit twice")
end

# --- read once ----------------------------------------------------------------
ROOT_REAL = File.realpath(ROOT)
units.each do |u|
  origin = "#{opt[:manifest]}:#{u['line']}"
  File.file?(u["abs"]) or refuse("missing-file", "#{u['path']} is not a file under the root", origin)
  # RESOLVED, not merely expanded. `File.expand_path` removes `..` and does
  # not follow a link, so a link inside the root pointing out of it stayed
  # inside by that measure. The bytes that get packed are the bytes at the
  # other end of the link, so the other end is what has to be under the root.
  real = File.realpath(u["abs"])
  unless real == ROOT_REAL || real.start_with?(ROOT_REAL + File::SEPARATOR)
    refuse("outside-root", "#{u['path']} resolves to #{real}, which is outside #{ROOT_REAL}", origin)
  end
  u["bytes"] = File.binread(u["abs"])
  got = Digest::SHA256.hexdigest(u["bytes"])
  got == u["sha"] or
    refuse("digest", "#{u['path']} is sha256 #{got}, the manifest says #{u['sha']}", origin)
end

# EVERY .rb UNDER THE ROOT IS ACCOUNTED FOR. A file the manifest does not list
# is not packed, and a source tree with an unpacked unit in it is a package
# that silently lost code.
listed = units.map { |u| u["abs"] }.to_set
stray = Dir.glob(File.join(ROOT, "**", "*.rb")).map { |p| File.expand_path(p) }.reject { |p| listed.include?(p) }
unless stray.empty?
  refuse("unlisted-unit",
         "#{stray.length} .rb file(s) under #{ROOT} are not in the manifest: " +
         stray.sort.map { |p| p.sub(ROOT + "/", "") }.join(", "))
end

# the entry's own units, in the manifest's order, once every .rb under the
# root has been accounted for against the whole manifest
units = units.select { |u| only.include?(u["path"]) } if only

# --- lexical refusals, on the captured bytes ----------------------------------
# These are token-level facts, not questions about definitions: a `__END__`
# line ends the program at that byte, and a file that is not UTF-8 cannot be
# concatenated with one that is. Neither is decided by looking at a `def`.
units.each do |u|
  origin = u["path"]
  text = u["bytes"].dup.force_encoding(Encoding::UTF_8)
  text.valid_encoding? or
    refuse("encoding", "is not valid UTF-8; the packed file has one encoding", origin)
  u["text"] = text
  text.each_line.with_index(1) do |line, n|
    refuse("end-marker", "line #{n} is __END__, which ends the program there and hides the rest " \
                         "from every unit packed after it", origin) if line.chomp == "__END__"
  end
  # A magic comment may only agree with the encoding the packed file has.
  first_two = text.each_line.first(2).join
  if (m = first_two.match(/^#.*coding[:=]\s*([-\w.]+)/))
    enc = m[1].downcase
    %w[utf-8 utf8 us-ascii ascii ascii-8bit binary].include?(enc) or
      refuse("encoding", "declares coding #{m[1]}, and the packed file is UTF-8", origin)
  end
end

# --- assemble -----------------------------------------------------------------
# Newline only. A unit that already ends in a newline gets nothing; one that
# does not gets exactly one, because otherwise its last line and the next
# unit's first would become one line and the map would be a lie.
# A packed compilation has one Integer domain; retain a captured unit's
# explicit wide declaration at the root, before any other unit's comments.
declares = units.select { |u| u["text"].lines.first&.chomp == "# spinel: int64" }
if width == "target" && !declares.empty?
  refuse("width", "#{opt[:entry]} is packed at the target's width, and #{declares.map { |u| u['path'] }.join(', ')} " \
                  "still declare(s) `# spinel: int64`")
end
wide = width ? width == "int64" : !declares.empty?
first_wide = units.first && units.first["text"].lines.first&.chomp == "# spinel: int64"
packed = +(wide && !first_wide ? "# spinel: int64\n" : "")
map = []
line = packed.count("\n") + 1
units.each do |u|
  body = u["text"]
  body += "\n" unless body.empty? || body.end_with?("\n")
  n = body.count("\n")
  n = 1 if n.zero?
  map << { "start" => line, "end" => line + n - 1, "path" => u["path"], "sha" => u["sha"] }
  packed << body
  line += n
end
packed_bytes = packed.b

# --- what the reader says ------------------------------------------------------
# Each unit and the assembled file are parsed separately. The assembled file's
# inventory must be exactly the union of the units', and the packing must not
# have created or lost a definition.
WORK = Dir.mktmpdir("pack-core")
at_exit { FileUtils.remove_entry(WORK) if Dir.exist?(WORK) }

# The reader prints its own diagnosis to stderr and exits nonzero; that text
# is the useful part and is left where it is. What is added here is the
# category and the ORIGIN, because the reader knows the temporary path it was
# handed and not which unit of which manifest that was.
def read_faces(reader, path, origin)
  led = path + ".inputs"
  ast_raw = ContractReader.run_face(reader, path, "ast", led)
  inputs = ContractReader.ledger_records(led, "ast")
  ledm = path + ".m.inputs"
  methods_raw = ContractReader.run_face(reader, path, "methods", ledm)
  ContractReader.ledger_records(ledm, "methods")
  [ContractReader.parse_ast(ast_raw), ContractReader.tsv(methods_raw, "methods", 3), inputs]
rescue ContractReader::Error => e
  refuse("syntax", "the reader could not parse it: #{e.message} (its diagnosis is above)", origin)
end

# A definition is unconditional when the chain from ROOT to it passes only
# through a program body, a statement list, a class body or a module body. The
# reader gives that chain; a regex could not see it.
CONTAINER = %w[ProgramNode StatementsNode ClassNode ModuleNode].freeze
DEFINING = %w[DefNode ClassNode ModuleNode ConstantWriteNode].freeze

def inventory(ast, origin)
  found = {}
  stack = [[ast.root, []]]
  until stack.empty?
    id, scope = stack.pop
    kind = ast.kind(id)
    case kind
    when "DefNode"
      nm = ast.sattr.fetch(id, {})["name"]
      key = (scope + [nm]).join("#")
      found.key?(key) and
        refuse("duplicate-definition", "defines #{key} twice", origin)
      found[key] = "method"
      next
    when "ConstantWriteNode"
      nm = ast.sattr.fetch(id, {})["name"]
      key = (scope + [nm]).join("::")
      found.key?(key) and refuse("duplicate-definition", "defines #{key} twice", origin)
      found[key] = "constant"
      next
    when "ClassNode", "ModuleNode"
      cp = ast.ref.fetch(id, {})["constant_path"]
      nm = (cp && cp >= 0) ? ast.sattr.fetch(cp, {})["name"] : nil
      inner = nm ? scope + [nm] : scope
      ast.children(id).each { |c| stack.push([c, inner]) }
      next
    end
    ast.children(id).each { |c| stack.push([c, scope]) } if CONTAINER.include?(kind) || kind.nil?
  end
  found
end

def top_level_shape(ast, origin)
  st = ast.ref.fetch(ast.root, {})["statements"]
  return if st.nil? || st < 0
  ast.arr.fetch(st, {}).fetch("body", []).each do |id|
    kind = ast.kind(id)
    next if DEFINING.include?(kind)
    if kind == "CallNode" && ast.sattr.fetch(id, {})["name"].to_s.start_with?("require")
      refuse("require-relative", "loads another file at the top level; the packed unit is one file " \
                                 "and the manifest is what says which", origin)
    end
    refuse("top-level-execution",
           "runs a #{kind} at the top level; a packed source unit may only define", origin)
  end
end

# THE CAPTURED BYTES ARE WHAT IS PARSED, laid out under their own relative
# paths so a unit that loads a sibling actually finds it. Parsing each unit
# alone in a private directory would turn every `require_relative` into the
# reader's own "cannot load such file", which names the wrong problem: the
# refusal here is that a source unit reached for another file at all, and
# the ledger is what says it did.
shadow = File.join(WORK, "root")
units.each do |u|
  dst = File.join(shadow, u["path"])
  FileUtils.mkdir_p(File.dirname(dst))
  File.binwrite(dst, u["bytes"])
  u["shadow"] = dst
end

unit_inventories = {}
units.each do |u|
  ast, _methods, inputs = read_faces(READER, u["shadow"], u["path"])
  outside = inputs.reject { |p| p == File.realpath(u["shadow"]) }
  unless outside.empty?
    others = outside.map { |p| p.sub(File.realpath(shadow) + "/", "") }
    refuse("require-relative",
           "reading it also opened #{others.sort.join(', ')}; a packed source unit stands alone " \
           "and the manifest is what says which units there are", u["path"])
  end
  top_level_shape(ast, u["path"])
  unit_inventories[u["path"]] = inventory(ast, u["path"])
end

# The units may not collide with each other either.
combined = {}
unit_inventories.each do |path, inv|
  inv.each do |key, what|
    if (prev = combined[key])
      refuse("duplicate-definition",
             "#{path} defines #{key}, which #{prev} already defines", path)
    end
    combined[key] = path
  end
end

packed_path = File.join(WORK, "packed.rb")
File.binwrite(packed_path, packed_bytes)
packed_ast, _pm, packed_inputs = read_faces(READER, packed_path, opt[:output])
packed_outside = packed_inputs.reject { |p| p == File.realpath(packed_path) }
packed_outside.empty? or
  refuse("require-relative", "reading the packed file opened #{packed_outside.join(', ')}", opt[:output])
top_level_shape(packed_ast, opt[:output])
packed_inv = inventory(packed_ast, opt[:output])

missing = combined.keys - packed_inv.keys
extra = packed_inv.keys - combined.keys
unless missing.empty? && extra.empty?
  refuse("inventory",
         "the packed file does not define what the units do" +
         (missing.empty? ? "" : "; lost: " + missing.sort.join(", ")) +
         (extra.empty? ? "" : "; gained: " + extra.sort.join(", ")))
end

# --- a mutation after capture cannot move this build --------------------------
moved = units.reject { |u| File.file?(u["abs"]) && File.binread(u["abs"]) == u["bytes"] }
unless moved.empty?
  warn("#{PROG}: note: #{moved.length} unit(s) changed on disk after they were read " \
       "(#{moved.map { |u| u['path'] }.sort.join(', ')}); this package is the bytes that were " \
       "captured, and the map and digests describe those")
end

# --- publish ------------------------------------------------------------------
def publish(dest, bytes)
  FileUtils.mkdir_p(File.dirname(dest))
  tmp = File.join(File.dirname(dest), ".#{File.basename(dest)}.#{Process.pid}.tmp")
  File.binwrite(tmp, bytes)
  File.rename(tmp, dest)
rescue SystemCallError => e
  FileUtils.rm_f(tmp) if tmp
  refuse("output", "cannot write #{dest}: #{e.message}")
end

map_text = +""
map_text << "# pack-core map\n"
map_text << "# packed\tsha256:#{Digest::SHA256.hexdigest(packed_bytes)}\n"
map_text << "# manifest\tsha256:#{Digest::SHA256.file(opt[:manifest]).hexdigest}\n"
map_text << %w[packed_start_line packed_end_line path source_sha256].join("\t") << "\n"
map.each { |m| map_text << [m["start"], m["end"], m["path"], m["sha"]].join("\t") << "\n" }
# Where a packed `# spinel: int64` comes from, for a diagnostic that names it
# (decision 0019): the manifest line giving this entry's width, and the units
# that declare it themselves. Comments, so a reader of the rows is unchanged.
map_text << "# width\t#{opt[:entry]}\t#{width}\tmanifest line #{width_lines[opt[:entry]]}\n" if width
map_text << "# declares int64\t#{declares.map { |u| u['path'] }.join(',')}\n" unless declares.empty?

publish(opt[:output], packed_bytes)
publish(opt[:map], map_text.b)

warn("#{PROG}: packed #{units.length} unit(s), #{packed_bytes.count("\n")} line(s), " \
     "#{combined.size} definition(s) -> #{opt[:output]}")
