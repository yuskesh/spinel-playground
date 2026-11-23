# frozen_string_literal: true
#
# tools/doom/audit-core.rb — decision 0008 task 1's audit.
#
#   ruby tools/doom/audit-core.rb --output DIR [--reader PATH] [--entry PATH]
#
# ONE SOURCE OF FACTS. Everything comes from the pinned contract reader,
# tools/contract/build/spinel-typedump. The reader is the parser the
# eligibility checker sees, so a call it does not report is one the checker
# will not see either. The reader parses with the Prism that vendor builds
# (1.9.0); an earlier revision of this comment said the audit uses "neither"
# that nor CRuby's 0.19.0, which was wrong about the reader. What the audit
# does not use is CRuby's own Prism.
#
# THE WIRE FORMAT IS THE READER'S, NOT A GUESS. tools/mlir/native/lib/Contract/
# Reader.cpp's parseAstFace is the specification and this follows it: an `A`
# line's value is a COMMA-SEPARATED LIST (`A 1 body 2,8,20,41`), an empty array
# is legal, and on an `R` line only -1 means "no reference" -- a missing field
# is a different thing from -1 and must not become node 0.
#
# An earlier revision read only the first element of an `A` line and concluded
# from the wreckage that the `ast` face "is not a connected tree for a
# multi-file closure", with 11377 parentless nodes and 549 of 556 DefNodes
# among them. THAT WAS THIS FILE'S BUG, not the reader's shape: read the CSV
# properly and all 59343 nodes are reachable from ROOT with exactly one
# parentless node. The claim is withdrawn.
#
# THIS IS NOT THE SYNTAX CENSUS. docs/core/doom-closure-gaps.md counts 571
# definitions in the tree; this walks the reachable graph from named roots.
# 0008 forbids using one as the other.
#
# INCOMPLETE IS A FAILURE. Ambiguity, an unresolved name, a missing output or
# a root set that does not yet cover 0008's entries all make this exit nonzero.

require_relative "contract_reader"
require "optparse"
require "shellwords"
require "set"
require "digest"

opt = {}
OptionParser.new do |o|
  o.on("--output DIR") { |v| opt[:output] = v }
  o.on("--reader PATH") { |v| opt[:reader] = v }
  o.on("--entry PATH") { |v| opt[:entry] = v }
  o.on("--tables DIR") { |v| opt[:tables] = v }
  o.on("--builtins PATH") { |v| opt[:builtins] = v }
  o.on("--effects PATH") { |v| opt[:effects] = v }
  o.on("--state PATH") { |v| opt[:state] = v }
  o.on("--fields PATH") { |v| opt[:fields] = v }
  o.on("--counts PATH") { |v| opt[:counts] = v }
  o.on("--acquired PATH") { |v| opt[:acquired] = v }
  o.on("--receivers PATH") { |v| opt[:receivers] = v }
  o.on("--cycles PATH") { |v| opt[:cycles] = v }
  o.on("--configurations PATH") { |v| opt[:configurations] = v }
  o.on("--unreached PATH") { |v| opt[:unreached] = v }
  o.on("--roots-complete") { opt[:roots_complete] = true }
  # For the controls only: the audit must be testable against a small input
  # whose roots are not DOOM's. It never relaxes the checks, only names them.
  o.on("--roots LIST") { |v| opt[:roots] = v.split(",") }
end.parse!
abort("audit-core: --output DIR is required") unless opt[:output]

ROOT = File.expand_path("../..", __dir__)
# WHERE THE TABLES LIVE. Beside this script by default, because a guessed
# repository root is wrong for a copy of the audit run from elsewhere -- which
# is how the controls mutate it. `--tables DIR` moves all five at once and
# each table's own option still overrides one, which is how a control can
# corrupt exactly one of them.
TABLES = opt[:tables] || __dir__
READER = opt[:reader] || File.join(ROOT, "tools", "contract", "build", "spinel-typedump")
ENTRY = opt[:entry] || File.join(ROOT, "examples", "doom", "bin", "doom.rb")
File.executable?(READER) or abort("audit-core: no reader at #{READER}")
File.exist?(ENTRY) or abort("audit-core: no entry at #{ENTRY}")

# --- ONE FIXED INPUT, AND A LEDGER PER FACE -----------------------------------
# Class attribution comes from the reader's own `methods` face, and includes
# from walking the tree; no regex reads Ruby here. The three faces share one id
# space, measured: node 25 is the same CallNode in `nodes` and in `ast`.
#
# THE READER ACCOUNTS FOR ITS OWN INPUTS, IN EVERY MODE. `--inputs-out=PATH` is
# not an `ast` feature: tools/contract/spinel_typedump.c:452-501 accepts it in
# every mode and enables recording before the parse, and tools/mlir/native/lib/
# Core/Input.cpp:104-128 already demands a ledger from every face and checks it
# before the next face runs. An earlier revision of this file said the other
# faces' inputs could not be verified because only `ast` emits a FILE table.
# That was wrong, and it confused two different things: the FILE table names
# the files the ast face REPORTS, the ledger names the files the frontend
# OPENED. Measured here, all five of ast/nodes/methods/globals/info exit 0 and
# write a non-empty NUL-terminated ledger of realpath-resolved absolute paths
# (vendor/spinel/src/spinel_parse.c:sp_inputs_record resolves each entry, and
# sp_inputs_write refuses to write an empty or unaccounted-for ledger).
#
# So the closure is fixed FROM THE LEDGER, not from the FILE table:
#
#   1. DISCOVERY runs `ast` on the caller's entry with its own ledger. What
#      that ledger names -- the files the frontend actually opened -- is the
#      snapshot set.
#   2. Those bytes are copied into a private directory.
#   3. Each PRODUCTION face runs on the snapshot's entry with its OWN ledger,
#      and that ledger is checked BEFORE the next face runs: non-empty, NUL
#      terminated, no empty record, the entry present, every path inside the
#      snapshot, and the set equal BY NAME to what was frozen.
#   4. THE OUTPUT OF THE CHECKED RUN IS THE OUTPUT THAT IS USED. Running one
#      face to inspect it and then reading three more cannot authenticate those
#      three, which is exactly what the previous structure did. Each face's raw
#      output is bound to its own ledger, and both digests are written into the
#      report header.
#
# macOS demonstrated why with two probes. One swapped `Other.new.target` for
# `Game.new.target` between the `nodes` read and the `ast` read; the run then
# reported the NEW file's digest while resolving by the OLD one. The other
# climbed `../` thirty-two times and then named the original dependency by its
# absolute path minus the leading slash, so a two-file snapshot still had the
# snapshot's own entry reading one original file -- two against two, which
# counting cannot see. Hashing paths after the fact detects neither.
require "tmpdir"
require "fileutils"

def decode_path(p) = ContractReader.decode_path(p)

def inside?(path, root)
  a = File.expand_path(path)
  a == root || a.start_with?(root + File::SEPARATOR)
end

LEDGERS = Dir.mktmpdir("audit-core-ledger")
at_exit { FileUtils.remove_entry(LEDGERS) if Dir.exist?(LEDGERS) }

# THE MODE STAYS LAST. It has always been the final argument and a wrapper
# around the reader may key on that; Input.cpp:111-113 places the ledger flag
# before the mode for the same reason, and says so.
# Every reader call, every ledger check and every parse goes through
# tools/doom/contract_reader.rb, which is the one place this repository's Ruby
# side reads the pinned reader's wire format. A second half-validated copy of
# that parser is exactly what the reader exists to prevent.
def wire
  yield
rescue ContractReader::Error => e
  abort("audit-core: #{e.message}")
end

def run_face(reader, entry, mode, ledger_path)
  wire { ContractReader.run_face(reader, entry, mode, ledger_path) }
end

# The ledger's wire contract, and the whole of it: a non-empty sequence of
# non-empty NUL-TERMINATED records. This is Input.cpp's checkLedger minus its
# single-file rule -- that one rejects any path but the source because its
# slice compiles one file; this closure has many, so the set is checked against
# the snapshot below instead of against one name.
def ledger_records(path, face)
  wire { ContractReader.ledger_records(path, face) }
end

def normalize(paths)
  paths.map { |p| File.exist?(p) ? File.realpath(p) : File.expand_path(p) }
end

# --- 1. discovery -------------------------------------------------------------
disc_ledger = File.join(LEDGERS, "discovery.ast.inputs")
run_face(READER, ENTRY, "ast", disc_ledger)
DISCOVERED = normalize(ledger_records(disc_ledger, "discovery/ast")).uniq.sort.freeze
ENTRY_REAL = File.realpath(ENTRY)
DISCOVERED.include?(ENTRY_REAL) or
  abort("audit-core: the discovery ledger does not name the entry #{ENTRY_REAL}, " \
        "so it does not describe this run")

# --- 2. freeze ----------------------------------------------------------------
# RESOLVED AT CREATION, so every path derived from it is the one the reader will
# report. Dir.mktmpdir answers $TMPDIR's own spelling, and where that is a
# symlink -- macOS resolves /var to /private/var, and any TMPDIR through a link
# does the same -- the snapshot's paths and their realpaths are different
# strings. Everything below compares them: the entry's file id, the input
# ledgers, `inside?`. Resolving here rather than at each comparison is why there
# is one rule instead of one per site.
SNAP = File.realpath(Dir.mktmpdir("audit-core-snap"))
at_exit { FileUtils.remove_entry(SNAP) if Dir.exist?(SNAP) }
prefix = DISCOVERED.reduce { |a, b| a.chars.zip(b.chars).take_while { |x, y| x == y }.map(&:first).join }
prefix = File.dirname(prefix) unless Dir.exist?(prefix)
DISCOVERED.each do |abs|
  dst = File.join(SNAP, abs.sub(/\A#{Regexp.escape(prefix)}\/?/, ""))
  FileUtils.mkdir_p(File.dirname(dst))
  FileUtils.cp(abs, dst)
end
SNAP_REAL = File.realpath(SNAP)
SNAP_ENTRY = File.join(SNAP, ENTRY_REAL.sub(/\A#{Regexp.escape(prefix)}\/?/, ""))
File.exist?(SNAP_ENTRY) or abort("audit-core: the entry is not among the files the reader opened")
FROZEN = normalize(DISCOVERED.map { |abs| File.join(SNAP, abs.sub(/\A#{Regexp.escape(prefix)}\/?/, "")) }).sort.freeze
SNAP_ENTRY_REAL = File.realpath(SNAP_ENTRY)

# --- 3. every production face, checked before the next one runs ---------------
def verify_inputs(recs, face, frozen, snap_real, entry_real)
  bad = ->(m) { abort("audit-core: input ledger (#{face}): #{m}") }
  seen = normalize(recs).uniq.sort
  outside = seen.reject { |p| inside?(p, snap_real) }
  unless outside.empty?
    bad.call("#{outside.length} input(s) from OUTSIDE the snapshot, so the run is not " \
             "over fixed bytes:\n  " + outside.join("\n  "))
  end
  seen.include?(entry_real) or
    bad.call("the ledger does not name the entry #{entry_real}, so it does not describe this run")
  return seen if seen == frozen
  bad.call("a different set than was frozen (#{seen.length} read, #{frozen.length} frozen)\n" \
           "  only in the read:     " + (seen - frozen).join(", ") + "\n" \
           "  only in the snapshot: " + (frozen - seen).join(", "))
end

FACES = %w[nodes ast methods].freeze
RAW = {}
LEDGER_PATH = {}
INPUTS = {}
FACES.each do |f|
  LEDGER_PATH[f] = File.join(LEDGERS, "production.#{f}.inputs")
  RAW[f] = run_face(READER, SNAP_ENTRY, f, LEDGER_PATH[f])
  INPUTS[f] = verify_inputs(ledger_records(LEDGER_PATH[f], f), f, FROZEN, SNAP_REAL, SNAP_ENTRY_REAL)
end
nodes_raw = RAW["nodes"]
ast_raw = RAW["ast"]
methods_raw = RAW["methods"]

# --- THE WIRE CONTRACT THIS FILE CONSUMES, AND ALL OF IT ----------------------
# tools/mlir/native/lib/Contract/Reader.cpp is the reference. An earlier
# revision documented that this file made none of that reader's structural
# checks; documenting a gap is not closing it, so the subset of the format this
# file reads is LIMITED and VALIDATED instead. For the tabular faces: a header
# is required, every row has the header's width, and an id is declared once.
# For `ast`: every record tag is one of the eight the reader emits, a node is
# declared exactly once, a field key is set at most once per node, a field is
# never set on an undeclared node, and every link -- an `R` that is not -1, and
# every element of an `A` -- names a declared node. Anything else is refused by
# name rather than read as whatever `to_i` returns for it.
#
# `I` values are NOT links. `node_file` holds a FILE id and the rest are plain
# integers, so validating them against the node set would be a category error.
def tsv(raw, face, want_cols)
  wire { ContractReader.tsv(raw, face, want_cols) }
end

kind = {}; ntype = {}; nscope = {}; ndetail = {}; nline = {}; ncol = {}; nfile = {}
nscope_name = {}
tsv(nodes_raw, "nodes", 8).each do |f|
  i = Integer(f[0], 10)
  kind.key?(i) and abort("audit-core: the nodes face declares node #{i} twice")
  kind[i] = f[1]; ntype[i] = f[2]; nscope[i] = f[3]; nline[i] = f[5]; ncol[i] = f[6]; ndetail[i] = f[7]
  nscope_name[f[3]] ||= f[4]
end

ast = wire { ContractReader.parse_ast(ast_raw) }
wire { ContractReader.check_kinds(ast, kind) }
files = ast.files
declared = ast.declared
ref = ast.ref
iattr = ast.iattr
sattr = ast.sattr
arr = ast.arr
# `arr` and `ref` come back as plain hashes; the walks below index missing
# keys, so give them the same empty defaults they had when they were built
# here. `ref[id].fetch("receiver", nil)` must still say nil, not -1 or 0.
arr.default_proc = proc { |h, k| h[k] = Hash.new { |g, j| g[j] = [] } }
arr.each_value { |v| v.default_proc = proc { |g, j| g[j] = [] } }
ref.default_proc = proc { |h, k| h[k] = {} }
iattr.default_proc = proc { |h, k| h[k] = {} }
sattr.default_proc = proc { |h, k| h[k] = {} }
kind.each_key { |i| nfile[i] = files[iattr[i]["node_file"]] }

defs = {}; scope_cls = {}
method_rows = tsv(methods_raw, "methods", 3)
# Classes by their Ruby names (ContractReader.ruby_class_names): the methods
# face and an `obj_` type give the reader's spelling, the ast and the tables
# here the Ruby one.
class_name = wire { ContractReader.ruby_class_names(method_rows.map { |f| f[2] }) }
ntype.transform_values! do |t|
  t.start_with?("obj_") ? "obj_" + class_name.fetch(t.delete_prefix("obj_"), t.delete_prefix("obj_")) : t
end
method_rows.each do |f|
  scope, name, cls = f[0], f[1], class_name.fetch(f[2], f[2])
  key = "#{cls}##{name}"
  defs.key?(key) and abort("audit-core: #{key} is defined twice; a call cannot be attributed")
  defs[key] = { "name" => name, "cls" => cls, "scope" => scope }
  scope_cls[scope] = key
end

reader_id = "sha256:" + Digest::SHA256.file(READER).hexdigest[0, 16]
# The bytes THAT WERE READ, named by the ledgers of the runs that read them.
# Every face's raw output is bound to its own ledger here, so the report says
# which bytes each face accounted for rather than asserting they agreed.
ledger = FROZEN.map do |p|
  "#{p.sub(SNAP_REAL + '/', '')}\t#{Digest::SHA256.file(p).hexdigest}"
end
face_binding = FACES.map do |f|
  "#{f}\toutput=#{Digest::SHA256.hexdigest(RAW[f])[0, 16]}" \
  "\tledger=#{Digest::SHA256.file(LEDGER_PATH[f]).hexdigest[0, 16]}\tinputs=#{INPUTS[f].length}"
end

# Includes, from the tree. Now that the `A` lines parse, the ast IS connected,
# so the class that hosts an `include` is found by walking down and carrying
# the enclosing ClassNode/ModuleNode -- not from the call's scope name, which
# for a class body is the file's top level and gave `(top)`.
# ACCESSORS THE `methods` FACE DOES NOT REPORT. `attr_reader`, `attr_writer`
# and `attr_accessor` define real methods that real calls reach, and the
# reader's `methods` face does not list them: measured, `Game#player_mo` and
# `Game#pl_attacker` are called from the per-tic loop and appear nowhere in
# that face. Treating those calls as unresolved would charge the audit for a
# gap that is not in the program, so the definitions are recovered from the
# same structural walk that finds `include` -- an `attr_*` CallNode in a
# class or module body, whose arguments are SymbolNodes.
#
# They are DEFINITIONS WITHOUT A BODY: an accessor reads or writes one ivar,
# it allocates nothing and calls nothing, so it has no scope in the `nodes`
# face and contributes no outgoing edge. That is why it is recorded with its
# origin rather than merged into the `methods` face's entries.
ATTR_CALLS = { "attr_reader" => [""], "attr_writer" => ["="],
               "attr_accessor" => ["", "="] }.freeze

includes = Hash.new { |h, k| h[k] = [] }
attrs = {}
host_walk = lambda do |id, host|
  return if id.nil? || id < 0
  here = host
  if kind[id] == "ClassNode" || kind[id] == "ModuleNode"
    cp = ref[id].fetch("constant_path", -1)
    here = (cp >= 0 && ndetail[cp] && !ndetail[cp].empty?) ? ndetail[cp] : host
  elsif kind[id] == "CallNode" && host
    a = ref[id].fetch("arguments", -1)
    args = a >= 0 ? arr[a]["arguments"] : []
    if ndetail[id] == "include"
      args.each { |c| includes[host] << ndetail[c] if kind[c] == "ConstantReadNode" }
    elsif (suffixes = ATTR_CALLS[ndetail[id]])
      args.each do |c|
        next unless kind[c] == "SymbolNode"
        nm = ndetail[c].to_s
        next if nm.empty?
        suffixes.each { |sfx| attrs["#{host}##{nm}#{sfx}"] = ndetail[id] }
      end
    end
  end
  kids = ref[id].values.reject { |v| v < 0 } + arr[id].values.flatten
  kids.each { |c| host_walk.call(c, here) }
end
host_walk.call(0, nil)
includes.each_value(&:uniq!)

# A class cannot have an accessor and a def of the same name; if the reader
# reports both, the two sources disagree and the audit says so rather than
# picking one.
attrs.each do |key, origin|
  if defs.key?(key)
    abort("audit-core: #{key} is reported by the methods face AND generated by " \
          "#{origin} in the tree; the two sources disagree about one definition")
  end
  cls, name = key.split("#", 2)
  defs[key] = { "name" => name, "cls" => cls, "scope" => nil, "attr" => origin }
end

# --- the 150 bodies the ast face does not carry ------------------------------
# MEASURED, and an earlier revision of this file had it wrong. It called the
# 3875 CallNodes that the `nodes` face reports and the `ast` face does not
# "analysis-synthesized", as if they had no source. They have one.
#
#   ast DefNodes                                             556
#   methods-face entries                                     706
#   scopes whose nodes are ENTIRELY absent from the ast      150
#   scopes partly in the ast and partly not                    0
#
# 150 = MapMove 27 + Specials 47 + Enemy 34 + Pspr 24 + Inter 13 + Sight 5:
# exactly the six modules Game includes, and every one of those 150 entries
# is also present under its module. So the reader reports an included
# module's method TWICE -- once syntactically, under the module, with the
# ast tree; and once per including class, as a separate scope whose nodes
# carry that class's resolved types and no ast node at all. There is nothing
# synthetic about them; they are the same source, instantiated.
#
# That gives each one a twin, and the twin has the receiver link. Measured on
# DOOM: of the 3875, 3815 have exactly one ast node at the same (line,
# column, kind, name) in the twin scope, 37 have several and 23 have none.
# The receiver's TYPE is then read from the INSTANTIATED scope, not from the
# twin -- per-class instantiation is the whole reason the two differ.
#
# A scope with no twin, or more than one candidate twin, gets no receiver
# from here and stays unresolved. Guessing across instantiations is how the
# receiver was lost in the first place.
scope_nodes = Hash.new { |h, k| h[k] = [] }
kind.each_key { |i| scope_nodes[nscope[i]] << i }
ast_scopes, instantiated_scopes =
  scope_nodes.keys.partition { |s| scope_nodes[s].any? { |i| declared.key?(i) } }
name_of_scope = ->(s) { (k = scope_cls[s]) && defs[k] && defs[k]["name"] }
class_of_scope = ->(s) { (k = scope_cls[s]) && defs[k] && defs[k]["cls"] }
position = ->(i) { [nline[i], ncol[i], kind[i], ndetail[i]] }

twin_scope = {}
twin_scope_why = Hash.new(0)
instantiated_scopes.each do |s|
  nm = name_of_scope.call(s)
  unless nm
    twin_scope_why["no methods-face entry"] += 1
    next
  end
  # Only in a module this class includes. Matching by name alone made
# `Game#set_psprite` ambiguous between `Pspr#set_psprite` (the module it
# came from) and `Renderer#set_psprite` (an unrelated class that happens to
# use the name), so no twin was recorded and twelve call sites lost their
# receiver.
host = class_of_scope.call(s)
from_mods = includes.fetch(host, [])
cands = ast_scopes.select do |a|
  name_of_scope.call(a) == nm && from_mods.include?(class_of_scope.call(a))
end
  if cands.length == 1 then twin_scope[s] = cands.first
  else twin_scope_why[cands.empty? ? "no twin scope" : "several twin scopes"] += 1
  end
end

# node in an instantiated scope -> its unique ast twin, and back again.
twin_node = {}
back_node = {}
twin_scope.each do |s, a|
  fwd = Hash.new { |h, k| h[k] = [] }
  scope_nodes[a].each { |i| fwd[position.call(i)] << i }
  rev = Hash.new { |h, k| h[k] = [] }
  scope_nodes[s].each { |i| rev[position.call(i)] << i }
  scope_nodes[s].each do |i|
    c = fwd[position.call(i)]
    twin_node[i] = c.first if c.length == 1
  end
  scope_nodes[a].each do |i|
    c = rev[position.call(i)]
    back_node[i] = c.first if c.length == 1
  end
end

# ONE DEFINITION REPORTED TWICE IS NOT TWO CANDIDATES. An implicit `msg` from
# inside Game's family found both `Inter#msg` and `Game#msg` and called it
# ambiguous 58 times; they are the same source, once under the module and
# once instantiated for the class that included it. The instantiation is the
# one that executes -- it carries the types this class resolved -- so it wins
# and the module entry is dropped from the candidate set whenever both are
# in it. Nothing else is collapsed: two unrelated classes defining the same
# name stay ambiguous.
origin_key = {}
twin_scope.each do |s, a|
  inst = scope_cls[s]
  orig = scope_cls[a]
  origin_key[inst] = orig if inst && orig
end

by_name = Hash.new { |h, k| h[k] = [] }
defs.each_key { |k| by_name[k.split("#").last] << k }

# --- edges -------------------------------------------------------------------
# Three kinds, kept apart because they are different questions. A CALL is a
# named method invocation. An ALLOCATION is `X.new`, which also creates an
# INITIALIZATION edge to X#initialize -- an earlier revision listed `new` among
# "operators" by name alone and thereby erased both the allocation and
# everything `initialize` reaches. A BLOCK edge records that a call carries a
# block, whose body executes; `each`/`call`/`map` are not inert either.
#
# `builtin` here means ONLY "no definition in this tree". It says nothing about
# whether CORE can reach it, and no exclusion is implied by the label.
# Unary `-@` and `+@` are operators too, and an operator sent to an explicit
# receiver is no less an operator: `explicit-unknown` used to report `int / int`
# as an unresolved call because the check came after that branch.
OPERATOR = %w[
  [] []= + - * / % ** == != < > <= >= <=> << >> & | ^ ~ ! =~ !~ -@ +@
].to_set.freeze

# NODES THE ANALYSIS SYNTHESIZED. The `nodes` face reports CallNodes that the
# `ast` face does not carry -- 3875 of DOOM's 15046 -- because the analysis
# made them. They have no ast fields at all, so `ref[id]["block"]` is nil, and
# an earlier revision wrote `nil.to_i >= 0` and thereby fabricated a block on
# every one of them: it reported 3704 block edges where the ast holds 14. That
# number is withdrawn. A missing link is now distinguished from -1 everywhere,
# and a synthesized node is labelled rather than read as if it had structure.
in_ast = declared

edges = []
instantiated = 0
via_twin = 0
no_twin = 0
kind.each_key do |id|
  next unless kind[id] == "CallNode"
  from = scope_cls[nscope[id]]
  inst = !in_ast[id]
  instantiated += 1 if inst
  # A node the ast carries states its own receiver. A node from an
  # instantiated scope states none, so the link is read from its ast twin --
  # the same source position in the module the class included -- and the
  # receiver NODE is then mapped back into this scope, because the type that
  # matters is the one this instantiation resolved.
  src = id
  if inst
    tw = twin_node[id]
    if tw
      src = tw
      via_twin += 1
    else
      no_twin += 1
    end
  end
  rcv = ref[src].fetch("receiver", nil)
  rcv = back_node.fetch(rcv, rcv) if inst && src != id && rcv && rcv >= 0
  # THE RECEIVER'S OWN TYPE, not the call's. `Other.new.target` has target's
  # receiver be the `new` node, whose type the reader gives as `obj_Other`.
  # An earlier revision read the CALL's type column and misresolved: that is
  # the value the call produces, and says nothing about whom it was sent to.
  rcv_type = (rcv && rcv >= 0) ? ntype[rcv].to_s : nil
  # `obj_array` is not a class named "array": it is the reader's type for an
  # Array of object references (types.c, ty_is_obj_array), as `int_array` is
  # an Array of ints, so it names no class to narrow to.
  rcv_cls = rcv_type && rcv_type.start_with?("obj_") && rcv_type != "obj_array" ? rcv_type.sub("obj_", "") : nil
  rcv_cls ||= (rcv && rcv >= 0 && kind[rcv] == "ConstantReadNode") ? class_name.fetch(ndetail[rcv], ndetail[rcv]) : nil
  blk = ref[src].fetch("block", nil)
  edges << { "from" => from, "name" => ndetail[id], "node" => id,
             "file" => nfile[id] || nfile[src], "line" => nline[id],
             "inst" => inst, "twin" => (src == id ? nil : src),
             "rcv" => rcv, "rcv_cls" => rcv_cls, "rcv_type" => rcv_type,
             # An implicit receiver is `receiver -1`. An instantiated node
             # with no twin states nothing at all, which is a third state.
             "implicit" => (rcv == -1),
             "block" => (!blk.nil? && blk >= 0) }
end

# --- resolution --------------------------------------------------------------
# An IMPLICIT receiver resolves against the caller's class and what that class
# includes, and against classes that include the caller's module. An EXPLICIT
# receiver resolves against the named class only. Anything else is AMBIGUOUS
# and stays that way: a name occurring once in the whole tree is not evidence
# that it is this receiver's method.
def family_of(cls, includes)
  fam = [cls] + includes.fetch(cls, [])
  includes.each { |c, mods| fam << c if mods.include?(cls) }
  fam.compact.uniq
end

def resolve(e, defs, by_name, includes, origin_key)
  name = e["name"]
  cands = by_name[name]
  rc = e["rcv_cls"]
  collapse = lambda { |set| set.reject { |c| set.any? { |d| origin_key[d] == c } } }
  if rc
    narrowed = collapse.call(cands.select { |c| c.split("#").first == rc })
    return ["explicit", narrowed] unless narrowed.empty?
    return ["explicit-unknown", []]
  end
  if e["implicit"]
    from_cls = e["from"] ? e["from"].split("#").first : "(top)"
    fam = family_of(from_cls, includes)
    narrowed = collapse.call(cands.select { |c| fam.include?(c.split("#").first) })
    return ["implicit", narrowed] unless narrowed.empty?
  end
  # NO RECEIVER EVIDENCE. One surviving candidate is not the same state as a
  # resolved call: macOS's probe defines only Other#orphan and calls a bare
  # `orphan` from Game#g_ticker, and an earlier revision confirmed Other#orphan
  # with nothing ambiguous and nothing unresolved. A lone candidate is returned
  # separately so the caller cannot confirm it by counting.
  ["unnarrowed", cands]
end

# --- the Full-boundary catalog ------------------------------------------------
# A builtin is a callee with no definition in this tree. That is a statement
# about the tree, not a permission: whether CORE can reach it is answered
# per entry in tools/doom/core-builtins.tsv, and a builtin with no row there
# stays unresolved and fails the run.
# Beside this script, not under a guessed repository root: a copy of the audit
# run from elsewhere -- which is how the controls mutate it -- would otherwise
# look for the catalog next to the copy and abort before reading anything.
# `--builtins` names it explicitly, and the controls pass it.
BUILTINS_PATH = opt[:builtins] || File.join(TABLES, "core-builtins.tsv")
File.exist?(BUILTINS_PATH) or abort("audit-core: no builtin catalog at #{BUILTINS_PATH}")
VERDICTS = %w[core obligation full-boundary].freeze
BUILTINS = {}
File.foreach(BUILTINS_PATH).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  f.length == 4 or abort("audit-core: #{BUILTINS_PATH}:#{i}: #{f.length} column(s), want 4")
  recv, name, verdict, why = f
  VERDICTS.include?(verdict) or
    abort("audit-core: #{BUILTINS_PATH}:#{i}: verdict #{verdict.inspect} is not one of #{VERDICTS.join(', ')}")
  recv == "poly" and
    abort("audit-core: #{BUILTINS_PATH}:#{i}: `poly` is not a receiver a verdict can rest on; " \
          "it means the reader did not resolve the receiver")
  why.strip.empty? and abort("audit-core: #{BUILTINS_PATH}:#{i}: a verdict needs a reason")
  key = [recv, name]
  BUILTINS.key?(key) and abort("audit-core: #{BUILTINS_PATH}:#{i}: #{recv} #{name} is listed twice")
  BUILTINS[key] = verdict
end

# --- the roots, read off the per-tic loop ------------------------------------
# Not guessed. `examples/doom/bin/doom.rb`'s loop body is the whole of one
# tic, and every call in it that is not SDL belongs to one of 0008's three
# entries. The three that were here before covered only the tick, so the
# closure they produced was not the migration's closure and 0008's own exit
# criteria named work that could not be reached from them.
#
# What stays in Full, and why: `video.pump`, `read_keys` and `video.present`
# go through lib/doom/video.rb, which is the only file that touches SDL;
# `video.elapsed_us` and `video.delay_ms` read the clock, which by the
# example's own convention happens nowhere inside lib/doom; the frame-hash
# and stats writes are instrumentation. Allocation is Full's in every case.
# --- the receiver catalog -----------------------------------------------------
# `poly` is the reader saying it resolved the expression but not the class it
# produces. The audit will not guess -- one candidate is not a resolution --
# so the missing evidence is declared per (caller, callee, receiver type),
# which is stable under line moves. A row matching no call site fails.
RECV_PATH = opt[:receivers] || File.join(TABLES, "core-receivers.tsv")
File.exist?(RECV_PATH) or abort("audit-core: no receiver catalog at #{RECV_PATH}")
RECEIVERS = {}
File.foreach(RECV_PATH).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  f.length == 5 or abort("audit-core: #{RECV_PATH}:#{i}: #{f.length} column(s), want 5")
  caller_key, callee, rtype, declared_cls, why = f
  why.strip.empty? and abort("audit-core: #{RECV_PATH}:#{i}: a declared receiver needs a reason")
  declared_cls.strip.empty? and abort("audit-core: #{RECV_PATH}:#{i}: no class declared")
  key = [caller_key, callee, rtype]
  RECEIVERS.key?(key) and abort("audit-core: #{RECV_PATH}:#{i}: #{caller_key} #{callee} #{rtype} is listed twice")
  RECEIVERS[key] = declared_cls
end
receiver_used = Hash.new(0)
edges.each do |e|
  next unless e["rcv_cls"].nil? && e["from"]
  d = RECEIVERS[[e["from"], e["name"], e["rcv_type"].to_s]]
  next unless d
  receiver_used[[e["from"], e["name"], e["rcv_type"].to_s]] += 1
  # A declared class narrows like an explicit receiver; a declared primitive
  # type only replaces `poly`, so the builtin catalog can answer it.
  if d =~ /\A[A-Z]/ then e["rcv_cls"] = d else e["rcv_type"] = d end
end
receiver_unused = RECEIVERS.keys.reject { |k| receiver_used[k] > 0 }

DEFAULT_ROOTS = [
  # doom_core_input -- what turns a device state into this tic's command.
  ["TiccmdBuilder", "build", "input"],
  ["TiccmdBuilder", "quantize_angle!", "input"],
  ["KeyScript", "apply", "input"],
  ["DemoWriter", "write_tic", "input"],
  # doom_core_step -- the tick, and everything the loop runs after it that
  # still belongs to the simulation rather than to drawing.
  ["Random", "tic=", "step"],
  ["Random", "m_random", "step"],
  ["Game", "g_ticker", "step"],
  ["Game", "run_thinkers", "step"],
  ["Game", "dispatch_psp_action", "step"],
  ["Game", "point_to_angle2", "step"],
  ["Game", "take_message", "step"],
  ["StatusBar", "ticker", "step"],
  ["Hud", "ticker", "step"],
  # doom_core_render -- all CPU drawing, the status bar and the HUD included.
  ["Renderer", "clear_screen", "render"],
  ["Renderer", "set_psprite", "render"],
  ["Renderer", "set_psprite_flash", "render"],
  ["Renderer", "extralight=", "render"],
  ["Renderer", "render_player_view", "render"],
  ["Renderer", "draw_jobs_cpu", "render"],
  ["StatusBar", "draw", "render"],
  ["Hud", "draw", "render"],
  ["Hires", "blit_scale", "render"],
].freeze
ROOTS = (opt[:roots] ? opt[:roots].map { |k| c, n = k.split("#"); [c, n, "given"] }
                     : DEFAULT_ROOTS.to_a).freeze
ROOT_KINDS = %w[input step render].freeze

ROOTS.each { |c, n, _| defs.key?("#{c}##{n}") or abort("audit-core: root #{c}##{n} is not defined; the roots have drifted") }

edges_from = Hash.new { |h, k| h[k] = [] }
edges.each { |e| edges_from[e["from"]] << e if e["from"] }

# WHERE THE EDGE CAME FROM, ON EVERY ROW. An ast node states its own receiver,
# and -1 there means an implicit receiver, which IS evidence. A node from an
# instantiated scope states nothing and borrows its ast twin's link; one with
# no twin has no receiver evidence at all. Those are three different states and
# the resolution column alone cannot tell them apart, so the closure could not
# be read back to say what the remaining gap consists of.
#
# An earlier revision of this lambda still tested the edge key `synth`, which
# had been renamed: every row said `ast` and the 37 twinless nodes said
# nothing. Measured wrong for one commit, corrected here.
prov = lambda do |e|
  origin = e["inst"] ? (e["twin"] ? "instantiated-twin#{e['twin']}" : "instantiated-no-twin") : "ast"
  recv =
    if e["inst"] && !e["twin"] then "none-no-ast-twin"
    elsif e["implicit"] then "implicit"
    elsif e["rcv_type"] && !e["rcv_type"].empty? then e["rcv_type"]
    elsif e["rcv"] then "node#{e['rcv']}-#{kind[e['rcv']] || 'unknown'}"
    else "none"
    end
  [origin, recv]
end

# --- which entry reaches what -------------------------------------------------
# 0008 has three entries and the closure has to say which one a row belongs
# to: a definition reached only by `doom_core_render` is not part of the step,
# and one reached by two entries is shared state between them. So the walk is
# run once per entry, following exactly the edges the main walk follows, and
# each row carries the entries that reach its caller.
reach = lambda do |roots|
  got = {}
  q = roots.dup
  until q.empty?
    cur = q.shift
    next if got[cur]
    got[cur] = true
    edges_from[cur].each do |e|
      how, cands = resolve(e, defs, by_name, includes, origin_key)
      next if how == "unnarrowed" || cands.length != 1
      cands.each { |c| q << c unless got[c] }
      if e["name"] == "new" && e["rcv_cls"]
        init = "#{e['rcv_cls']}#initialize"
        q << init if defs.key?(init) && !got[init]
      end
    end
  end
  got.keys
end
domains_of = Hash.new { |h, k| h[k] = [] }
ROOT_KINDS.each do |k|
  rs = ROOTS.select { |_, _, kk| kk == k }.map { |c, n, _| "#{c}##{n}" }
  next if rs.empty?
  reach.call(rs).each { |d| domains_of[d] << k }
end
# A run given --roots has one unnamed kind; the domain is then that.
if domains_of.empty?
  reach.call(ROOTS.map { |c, n, _| "#{c}##{n}" }).each { |d| domains_of[d] << "given" }
end
domain_of = ->(k) { d = domains_of[k]; d.empty? ? "unreached" : d.join(",") }

seen = {}
rows = []
problems = { "ambiguous" => 0, "unresolved" => 0, "explicit-unknown" => 0, "block" => 0,
             "core" => 0, "obligation" => 0, "full-boundary" => 0, "block-disposed" => 0 }
queue = ROOTS.map { |c, n, _| "#{c}##{n}" }
until queue.empty?
  cur = queue.shift
  next if seen[cur]
  seen[cur] = true
  edges_from[cur].each do |e|
    how, cands = resolve(e, defs, by_name, includes, origin_key)
    kindname = "call"
    if e["name"] == "new"
      kindname = "allocation"
      init = e["rcv_cls"] ? "#{e['rcv_cls']}#initialize" : nil
      if init && defs.key?(init)
        rows << [cur, "initialization", "#{e['rcv_cls']}.new", e["file"], e["line"], *prov.call(e), domain_of.call(cur), init]
        queue << init unless seen[init]
      elsif init
        rows << [cur, "initialization", "#{e['rcv_cls']}.new", e["file"], e["line"], *prov.call(e), domain_of.call(cur), "NO-INITIALIZE"]
      else
        rows << [cur, "allocation", "new", e["file"], e["line"], *prov.call(e), domain_of.call(cur), "UNRESOLVED-RECEIVER"]
        problems["unresolved"] += 1
      end
    end
    if e["block"]
      # A block's body executes, so the edge is recorded. Its DISPOSITION is the
      # catalog's verdict on the call that carries it: every one of DOOM's twelve
      # is `loop`, whose row says the rewrite to `while true` puts the body back
      # among ordinary statements. A block on a call with no verdict is still
      # undisposed and still fails the run.
      bv = BUILTINS[[prov.call(e)[1], e["name"]]]
      rows << [cur, "block", e["name"], e["file"], e["line"], *prov.call(e), domain_of.call(cur),
               bv ? "BLOCK-BODY-#{bv.upcase}" : "BLOCK-BODY"]
      problems["block"] += 1 unless bv
      problems["block-disposed"] += 1 if bv
    end
    res =
      # An operator with no definition in this tree is builtin whatever it was
      # sent to. Checking that only after `explicit-unknown` reported `int / int`
      # as an unresolved call 20 times.
      if OPERATOR.include?(e["name"]) && cands.empty? then "builtin-operator"
      # A PRIMITIVE RECEIVER IS EVIDENCE THAT THE CALLEE IS NOT A TREE METHOD.
      # `text.bytesize` was reported as a candidate for `Wad#bytesize`, which is a
      # method of the same name on a class, because the catalog was consulted only
      # after the one-candidate branch. A tree method is never reached through an
      # int, a string or an array.
      elsif (pt = prov.call(e)[1]) && (!pt.start_with?("obj_") || pt == "obj_array") &&
            (pv = BUILTINS[[pt, e["name"]]])
        problems[pv] += 1
        "BUILTIN-#{pv.upcase}"
      elsif how == "unnarrowed" && !cands.empty?
        problems["unresolved"] += 1
        "UNRESOLVED-NO-RECEIVER-EVIDENCE:" + cands.join(",")
      elsif cands.length == 1 then cands.first
      elsif cands.length > 1 then (problems["ambiguous"] += 1; "AMBIGUOUS:#{how}:" + cands.join(","))
      elsif (v = BUILTINS[[prov.call(e)[1], e["name"]]])
        problems[v] += 1
        "BUILTIN-#{v.upcase}"
      elsif how == "explicit-unknown" then (problems["unresolved"] += 1; "UNRESOLVED-RECEIVER-CLASS")
      elsif OPERATOR.include?(e["name"]) then "builtin-operator"
      else (problems["unresolved"] += 1; "UNRESOLVED")
      end
    rows << [cur, kindname, e["name"], e["file"], e["line"], *prov.call(e), domain_of.call(cur), res]
    # An unnarrowed candidate is not followed: walking into a call whose
    # receiver is unknown would grow the closure on a guess.
    cands.each { |t| queue << t unless seen[t] || how == "unnarrowed" }
  end
end

# --- state-use ----------------------------------------------------------------
# Every instance variable the closure touches, with all its writers and
# readers, and a ROLE DERIVED from where those accesses are -- not asserted.
# 0007's four storage roles differ exactly by who writes and who reads:
#
#   resource    CORE reads it and never writes it, so Full must have it ready
#               before the entry is called
#   persistent  CORE writes and reads it, and it is also touched outside the
#               closure, so it survives the call
#   scratch     CORE writes and reads it and nothing outside the closure
#               touches it, so it lives only for the call
#   output      CORE writes it and does not read it back
#
# The OWNER is declared, one row per class, in tools/doom/core-state.tsv: a
# class whose storage the closure touches with no row there is unclassified
# and fails the run. A declared owner that the derived role contradicts --
# storage the closure writes in a class declared Full's -- fails too.
IVAR_KINDS = %w[InstanceVariableReadNode InstanceVariableWriteNode
                InstanceVariableOperatorWriteNode InstanceVariableAndWriteNode
                InstanceVariableOrWriteNode InstanceVariableTargetNode].to_set.freeze
STATE_PATH = opt[:state] || File.join(TABLES, "core-state.tsv")
File.exist?(STATE_PATH) or abort("audit-core: no state ownership table at #{STATE_PATH}")
OWNERS = %w[input step render shared full].freeze
OWNER = {}
File.foreach(STATE_PATH).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  f.length == 3 or abort("audit-core: #{STATE_PATH}:#{i}: #{f.length} column(s), want 3")
  cls, owner, why = f
  OWNERS.include?(owner) or
    abort("audit-core: #{STATE_PATH}:#{i}: owner #{owner.inspect} is not one of #{OWNERS.join(', ')}")
  why.strip.empty? and abort("audit-core: #{STATE_PATH}:#{i}: an owner needs a reason")
  OWNER.key?(cls) and abort("audit-core: #{STATE_PATH}:#{i}: #{cls} is declared twice")
  OWNER[cls] = owner
end

# --- where each array gets its size -------------------------------------------
# 0008's schema needs a `count` for every stored array, and that is the one
# thing the reader cannot say: it answers `int_array`, not how many elements
# the allocation asks for. So the ALLOCATION EXPRESSION is rendered from the
# tree -- the first argument of the `Array.new` or `Bytes.buffer` that creates
# the field -- and tools/doom/core-counts.tsv maps each (method, expression)
# pair to a catalog name.
#
# Keyed by the PAIR because `n` is a local and means a different thing in each
# method: `n = MAXMOBJS` in Game#init_mobjs and `n = data.bytesize / 26` in
# Level#load_sectors. An expression with no row is an array whose size nobody
# reviewed, and a row matching no allocation is a row describing nothing.
COUNTS_PATH = opt[:counts] || File.join(TABLES, "core-counts.tsv")
File.exist?(COUNTS_PATH) or abort("audit-core: no count table at #{COUNTS_PATH}")
COUNT_ROW = {}
File.foreach(COUNTS_PATH).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  f.length == 4 or abort("audit-core: #{COUNTS_PATH}:#{i}: #{f.length} column(s), want 4")
  meth, expr, count, why = f
  count =~ /\A(fixed|level|screen|limit|table):/ or
    abort("audit-core: #{COUNTS_PATH}:#{i}: count #{count.inspect} is not 0008's grammar")
  why.strip.empty? and abort("audit-core: #{COUNTS_PATH}:#{i}: #{meth} #{expr} needs a reason")
  key = [meth, expr]
  COUNT_ROW.key?(key) and abort("audit-core: #{COUNTS_PATH}:#{i}: #{meth} #{expr} is listed twice")
  COUNT_ROW[key] = count
end

# --- and the fields that are never allocated at all ----------------------------
# Some fields have no allocation site to read a count off: they are handed a
# table someone else built (`@finesine = Tables.finesine`), or they start as
# `[]` and are grown one push at a time while the WAD is read. Inventing
# `fixed:1` for those is what declared 151 prepared arrays a single element
# long. tools/doom/core-acquired.tsv names them by FIELD, and an array with
# neither an allocation site nor a row there is refused rather than guessed.
# The stored elements a joined array of strings can land in. One byte each, so
# the count is the joined byte length rather than the number of strings.
BYTE_ELEMENTS = %w[u8].freeze
ACQUIRED_PATH = opt[:acquired] || File.join(TABLES, "core-acquired.tsv")
File.exist?(ACQUIRED_PATH) or abort("audit-core: no acquired table at #{ACQUIRED_PATH}")
ACQUIRED = {}
File.foreach(ACQUIRED_PATH).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  f.length == 4 or abort("audit-core: #{ACQUIRED_PATH}:#{i}: #{f.length} column(s), want 4")
  field, count, origin, why = f
  field =~ /\A[A-Za-z_][A-Za-z0-9_]*@@?[a-z_][A-Za-z0-9_]*\z/ or
    abort("audit-core: #{ACQUIRED_PATH}:#{i}: #{field.inspect} is not Class@@ivar")
  count =~ /\A(fixed|level|screen|limit|table):/ or
    abort("audit-core: #{ACQUIRED_PATH}:#{i}: count #{count.inspect} is not 0008's grammar")
  origin.strip.empty? and abort("audit-core: #{ACQUIRED_PATH}:#{i}: #{field} needs an origin")
  why.strip.empty? and abort("audit-core: #{ACQUIRED_PATH}:#{i}: #{field} needs a reason")
  ACQUIRED.key?(field) and abort("audit-core: #{ACQUIRED_PATH}:#{i}: #{field} is listed twice")
  ACQUIRED[field] = count
end

# The expression, rendered from the tree and never from the source text.
render_count = lambda do |id|
  next "?" if id.nil? || id < 0
  case kind[id]
  when "IntegerNode" then (iattr[id]["value"] || ndetail[id] || "N").to_s
  when "ConstantReadNode", "LocalVariableReadNode", "InstanceVariableReadNode"
    # The ast's own spelling. The `nodes` face gives a constant its MANGLED
    # name (`Doom__StatusBar__NUMWEAPONS`), which is the generated C identifier
    # and not what anyone reviewing a count would write.
    (sattr[id]["name"] || ndetail[id]).to_s
  when "ArrayNode"
    # A LITERAL IS AN ALLOCATION WITH ITS SIZE WRITTEN OUT. `@fuzzoffset =
    # [1, -1, ...]` allocates 50 cells as plainly as `Array.new(50)` does.
    "[#{arr[id]['elements'].length} element(s)]"
  when "ConstantPathNode"
    # `Other::N`, and not the string "ConstantPathNode" -- which is what the
    # fallback below rendered, so a qualified constant would have gone into the
    # catalog under a key naming a node kind rather than an expression.
    pr = ref[id].fetch("parent", -1)
    nmp = (sattr[id]["name"] || ndetail[id]).to_s
    pr.is_a?(Integer) && pr >= 0 ? "#{render_count.call(pr)}::#{nmp}" : nmp
  when "CallNode"
    nm = ndetail[id].to_s
    r = ref[id].fetch("receiver", nil)
    a = ref[id].fetch("arguments", nil)
    args = (a && a >= 0) ? arr[a]["arguments"] : []
    if %w[+ - * / %].include?(nm) && args.length == 1
      "#{render_count.call(r)} #{nm} #{render_count.call(args[0])}"
    elsif r && r >= 0
      "#{render_count.call(r)}.#{nm}"
    else
      nm
    end
  else kind[id].to_s
  end
end

# (class or module that writes it, ivar name) -> the (method, expression) pairs
# that allocate it. An allocation written in a MODULE belongs to the classes
# that include it, which is resolved where a field's allocations are looked up.
allocation_of = Hash.new { |h, k| h[k] = [] }
allocation_fill = Hash.new { |h, k| h[k] = [] }
# And the SIZE NODE itself, keyed by the pair the catalog is keyed by, so a row
# can be checked against the very node it describes rather than against a
# string that was rendered from it.
allocation_size_node = Hash.new { |h, k| h[k] = [] }
# The write NODES that are allocations, so a later pass can tell an allocation
# from a write that changes what it allocated.
allocation_write_ids = {}
kind.each_key do |id|
  next unless kind[id] == "InstanceVariableWriteNode"
  v = ref[id].fetch("value", nil)
  next if v.nil? || v < 0
  size_node = nil
  fill = nil
  case kind[v]
  when "CallNode"
    nm = ndetail[v]
    next unless nm == "new" || nm == "buffer"
    a = ref[v].fetch("arguments", nil)
    args = (a && a >= 0) ? arr[a]["arguments"] : []
    next if args.empty?
    size_node = args[0]
    # The FILL as well as the count. `Array.new(n, -1)` opens at -1, not at 0,
    # and 30 allocations in DOOM's tree do exactly that; assuming zero made the
    # schema claim an initial state the game never has.
    fill = args.length > 1 ? render_count.call(args[1]) : "0"
  when "ArrayNode"
    # A NON-EMPTY LITERAL IS AN ALLOCATION. `@fuzzoffset = [1, -1, ...]` sizes
    # 50 cells as plainly as `Array.new(50)` does, and it was being missed
    # because it is not a call.
    #
    # AN EMPTY ONE IS NOT. `@lumps = []` says nothing about how long @lumps
    # ends up; the array is grown afterwards and its length is a fact about
    # the WAD. Calling that `fixed:0` would be the invented default this file
    # has been removing, in a new place -- so it falls through to the acquired
    # bucket and has to be reviewed.
    els = arr[v]["elements"]
    next if els.empty?
    size_node = v
    vals = els.map { |e| render_count.call(e) }.uniq
    fill = vals.length == 1 ? vals.first : "varies"
  else
    next
  end
  meth = scope_cls[nscope[id]]
  next unless meth
  owner = defs[meth]["cls"]
  allocation_of[[owner, ndetail[id]]] |= [[meth, render_count.call(size_node)]]
  allocation_fill[[owner, ndetail[id]]] |= [fill]
  allocation_write_ids[id] = true
  allocation_size_node[[meth, render_count.call(size_node)]] |= [size_node]
end

# --- and what a `fixed:` row claims that size is worth -------------------------
# The catalog's NAME carries a number, and until this check nothing compared it
# with the allocation it names. Three rows were wrong for as long as it took a
# reviewer to open defs.rb: `fixed:128` against MAXINTERCEPTS, which is 189;
# `fixed:8` against MAXSPECHIT, which is 20; `fixed:64` against MAXPLATS, which
# is 30. The first two had copied a PROCESSING limit into the place that says
# how long the allocation is -- `@ic_n >= 128` and `@numspechit >= 8` in
# mapmove.rb are real refusals and stay exactly as they are, but neither is the
# length of the array it guards.
#
# So every `fixed:` row is EVALUATED here from the tree's own constant and local
# definitions and refused by name when the number disagrees. A name resolves to
# one integer or to nothing: two definitions that do not agree, a local assigned
# in two places, or a call resolve to nothing rather than to a guess. And an
# unevaluated `fixed:` row is itself refused -- a count that is fixed is a count
# the tree can be asked for -- so a row cannot pass by being unreadable.
#
# AND WHAT MAY BIND A NAME IS A CLOSED LIST, with everything else refused.
# The first version of this collected `LocalVariableWriteNode` and nothing
# else. Mac review of a9d36ef changed one method's `n = 64` to
# `n = 64; n += 1`, left the `Array.new(n, 0)` and the catalog row alone, and
# this file still answered 64 and completed: an update is a
# `LocalVariableOperatorWriteNode` and nothing was looking at those. There are
# 460 of them in DOOM's tree. A parameter is the same kind of thing -- 777
# `RequiredParameterNode`s, each a name whose value is at the CALLER.
#
# So the test is over the KIND NAME and not over a list anyone has to keep:
# anything spelled `LocalVariable...` that is not a read BINDS, and so does
# anything spelled `...ParameterNode`. A name is evaluable only when the one
# thing that binds it is a single plain write. Anything else -- an update, a
# parameter, a second write, a form nobody has seen yet -- resolves to
# NOTHING, and an unevaluated `fixed:` row is refused rather than skipped.
local_binds = ->(k) { (k.start_with?("LocalVariable") && k != "LocalVariableReadNode") ||
                      k.end_with?("ParameterNode") }
# `ConstantPathNode` is a read form (`Doom::Fixed::FRACBITS`); a write through
# a path is `ConstantPathWriteNode` and binds like any other write.
const_binds = ->(k) { k.start_with?("Constant") && k != "ConstantReadNode" &&
                      k != "ConstantPathNode" }
local_value_node = Hash.new { |h, k| h[k] = [] }
const_write_node = Hash.new { |h, k| h[k] = [] }
local_write_node = Hash.new { |h, k| h[k] = [] }
const_binders = Hash.new(0)
local_binders = Hash.new(0)
kind.each_key do |id|
  k = kind[id]
  nm = (sattr[id]["name"] || ndetail[id]).to_s
  v = ref[id].fetch("value", nil)
  if local_binds.call(k)
    local_binders[[nscope[id], nm]] += 1
    if k == "LocalVariableWriteNode" && v && v >= 0
      local_value_node[[nscope[id], nm]] |= [v]
      local_write_node[[nscope[id], nm]] |= [id]
    end
  elsif const_binds.call(k)
    const_binders[nm.split("__").last.to_s] += 1
    const_write_node[nm.split("__").last.to_s] |= [id] if k == "ConstantWriteNode"
  end
end

# --- and whether that binding is reached before the read ----------------------
# COUNTING BINDINGS SAYS NOTHING ABOUT WHETHER ONE RUNS. Mac review of a9d36ef
# changed one method's `n = 64` to `n = 64 if false` and left everything else
# alone: still exactly one write, still one binder, and the real method raises
# because `Array.new(nil, 0)` is handed nil -- while this file answered 64 and
# completed. A conditional binding is a binding whose value the read may never
# see.
#
# The ast face is a connected tree (one parentless node), so the parent of
# every node is available and the question can be asked directly: does the path
# from the write up to its definition pass through anything that might not run?
parent_of = {}
kind.each_key do |id|
  ref[id].each_value { |c| parent_of[c] = id if c.is_a?(Integer) && c >= 0 && !parent_of.key?(c) }
  arr[id].each_value do |cs|
    cs.each { |c| parent_of[c] = id if c.is_a?(Integer) && c >= 0 && !parent_of.key?(c) }
  end
end

# The forms that always execute what they contain. CLOSED, and everything else
# refuses -- `IfNode`, `UnlessNode`, `WhileNode`, `CaseNode`, `WhenNode`,
# `ElseNode`, `BlockNode`, `AndNode`, `OrNode`, and equally any form nobody has
# met yet. This is not an interpreter and does not try to be one; it declines
# to answer for anything it cannot show is reached.
STRAIGHT_LINE = %w[StatementsNode DefNode ProgramNode ClassNode ModuleNode].freeze
runs_always_memo = {}
runs_always = lambda do |id|
  next runs_always_memo[id] if runs_always_memo.key?(id)
  # Guard against a cycle in the parent map, which would be this file's bug
  # rather than an answer: mark it unreachable before descending.
  runs_always_memo[id] = false
  p = parent_of[id]
  runs_always_memo[id] =
    if p.nil? then true
    elsif !STRAIGHT_LINE.include?(kind[p]) then false
    elsif %w[DefNode ProgramNode].include?(kind[p]) then true
    else runs_always.call(p)
    end
end

# --- WHICH definition a constant read means ------------------------------------
# "The only definition of that bare name in the tree" is not a conservative
# answer, it is an UNSOUND one, and Mac review showed it with four lines:
#
#     module Other; N = 64; end
#     class Game; def init; @buf = Array.new(N, 0); end; end
#
# The definition is unique, unconditional, and earlier than the read. CRuby
# says `uninitialized constant Game::N`. Uniqueness is evidence that a
# definition EXISTS; it is not evidence that THIS READ REACHES IT, and
# treating one candidate as settled is the same mistake this file already had
# to fix for call receivers. The `nodes` face does not settle it either: that
# read is `ConstantReadNode`, `detail=N`, typed `int`, and neither the bare
# spelling nor the type is a lookup.
#
# The structure is there to be used. A ClassNode or ModuleNode carries no name
# of its own, but it carries a `constant_path` link to a node that does, which
# is how `host_walk` above names a host. So the lexical path of any node is the
# chain of enclosing class and module names, and a read is resolved the way
# Ruby resolves it lexically: innermost enclosing scope first, outward to the
# top level, and the FIRST scope that defines the name wins.
#
# Where that finds nothing, Ruby would go on to the cref's ancestors -- and
# that needs the include and superclass graph, which is exactly the kind of
# thing a count check should not be deciding. `Game` includes six modules. So
# a read with no lexical definition is NOT EVALUATED. This is not a Ruby
# constant resolver and does not try to be one; it refuses the lookups it
# cannot show.
lexical_path = {}
path_of = lambda do |id|
  next lexical_path[id] if lexical_path.key?(id)
  lexical_path[id] = []          # a cycle would be this file's bug, not a path
  p = parent_of[id]
  here =
    if p.nil?
      []
    else
      up = path_of.call(p)
      if kind[p] == "ClassNode" || kind[p] == "ModuleNode"
        cp = ref[p].fetch("constant_path", -1)
        nmp = cp.is_a?(Integer) && cp >= 0 ? (sattr[cp]["name"] || ndetail[cp]).to_s : ""
        nmp.empty? ? up : up + [nmp]
      else
        up
      end
    end
  lexical_path[id] = here
end

# Every class and module path the tree defines, so `Other` in `Other::N` can be
# resolved to a scope rather than assumed to be one.
module_paths = Set.new
kind.each_key do |id|
  next unless kind[id] == "ClassNode" || kind[id] == "ModuleNode"
  cp = ref[id].fetch("constant_path", -1)
  nmp = cp.is_a?(Integer) && cp >= 0 ? (sattr[cp]["name"] || ndetail[cp]).to_s : ""
  module_paths << (path_of.call(id) + [nmp]) unless nmp.empty?
end

# path -> bare name -> the writes that define it there.
const_at = Hash.new { |h, k| h[k] = Hash.new { |g, j| g[j] = [] } }
kind.each_key do |id|
  next unless kind[id] == "ConstantWriteNode"
  bare = (sattr[id]["name"] || ndetail[id]).to_s.split("__").last.to_s
  next if bare.empty?
  const_at[path_of.call(id)][bare] |= [id]
end

# Innermost first, outward. Returns the writes at the first scope that has any,
# or nil when no enclosing scope defines the name at all.
#
# THE FIRST BINDING DECIDES, WHATEVER IT IS. Walking outward until something
# of the right KIND turns up is not Ruby's lookup, it is a search for a
# convenient answer: an inner binding of the name HIDES every outer one, and
# if the inner one is the wrong kind the program raises rather than looking
# further. So each scope is asked whether it binds the name at all, and the
# first that does ends the walk -- with an answer if it is a constant, with
# none if it is a class or module, which is not an integer.
const_lookup = lambda do |read_id, bare|
  path = path_of.call(read_id)
  found = nil
  # NOT `downto { break ws }`: with no `break` that returns the RECEIVER, so a
  # name no enclosing scope defines answered with an Integer -- which is what
  # the wrong-scope fixture crashed on, and would have been a truthy "result"
  # anywhere the crash had not been immediate.
  path.length.downto(0) do |n|
    scope = path.first(n)
    ws = const_at[scope][bare]
    shadowing_module = module_paths.include?(scope + [bare])
    next if ws.empty? && !shadowing_module
    found = ws unless ws.empty? || shadowing_module
    break
  end
  found
end

# The scope a QUALIFIER names. `Other` is looked up the same way a constant is
# -- innermost enclosing scope outward -- but what it has to find is a class or
# module the tree defines, and `A::B` is its parent resolved and then B. A
# qualifier that resolves to no known scope answers nothing.
module_path_of = nil
module_path_of = lambda do |id|
  next nil if id.nil? || id < 0
  nmp = (sattr[id]["name"] || ndetail[id]).to_s.split("__").last.to_s
  next nil if nmp.empty?
  case kind[id]
  when "ConstantReadNode"
    here = path_of.call(id)
    found = nil
    here.length.downto(0) do |n|
      scope = here.first(n)
      cand = scope + [nmp]
      is_module = module_paths.include?(cand)
      is_const = !const_at[scope][nmp].empty?
      # THE INNERMOST BINDING WINS EVEN WHEN IT IS THE WRONG KIND. Mac review
      # put `Other = 1` inside `Game` beside a `Doom::Other` module: CRuby
      # answers `1 is not a class/module`, and searching only `module_paths`
      # walked straight past the 1 to the module outside. A qualifier whose
      # first binding is not a scope is not a scope.
      next unless is_module || is_const
      found = cand if is_module && !is_const
      break
    end
    found
  when "ConstantPathNode"
    up = module_path_of.call(ref[id].fetch("parent", -1))
    next nil unless up
    cand = up + [nmp]
    module_paths.include?(cand) && const_at[up][nmp].empty? ? cand : nil
  end
end

# And BEFORE, by the position the tree carries. Same file or no answer: a
# comparison across files is not an ordering.
pos_before = lambda do |a, b|
  next false unless nfile[a] && nfile[a] == nfile[b]
  ([Integer(nline[a], 10), Integer(ncol[a], 10)] <=>
   [Integer(nline[b], 10), Integer(ncol[b], 10)]) < 0
end

eval_count = nil
# One integer or nothing, on the VALUES and not on the nodes: two spellings of
# `FINEANGLES = 8192` are one answer, and two spellings that disagree are none.
resolve_one = lambda do |nodes, seen|
  vals = nodes.map { |v| eval_count.call(v, seen) }.uniq
  vals.length == 1 ? vals.first : nil
end
eval_count = lambda do |id, seen|
  next nil if id.nil? || id < 0 || seen.include?(id)
  seen += [id]
  case kind[id]
  when "IntegerNode"
    t = (iattr[id]["value"] || ndetail[id]).to_s
    t =~ /\A-?\d+\z/ ? Integer(t, 10) : nil
  when "ConstantReadNode"
    # RESOLVED LEXICALLY, from the read's own scope outward, and refused when
    # that does not settle it. `FINEANGLES` is written three times in DOOM's
    # tree -- in `Doom`, in `Doom::Renderer`, in `Doom::Tables` -- so the bare
    # name names nothing on its own; and a name defined only in some unrelated
    # module is not in scope at all however unique it is.
    bare = (sattr[id]["name"] || ndetail[id]).to_s.split("__").last.to_s
    next nil if bare.empty?
    # Anything other than a plain write touching the name, anywhere, stops it:
    # scope decides WHICH definition, not whether something else changes one.
    next nil unless const_binders[bare] == const_write_node[bare].length
    ws = const_lookup.call(id, bare)
    next nil unless ws && ws.length == 1
    next nil unless runs_always.call(ws.first)
    # Where the face did resolve the name, its answer and this one must agree.
    # The face's spelling is used as a CHECK, never as the reason.
    spelled = ndetail[id].to_s
    if spelled.include?("__")
      next nil unless (path_of.call(ws.first) + [bare]).join("__") == spelled
    end
    eval_count.call(ref[ws.first].fetch("value", nil), seen)
  when "ConstantPathNode"
    # `Other::N`. The qualifier has to name a scope the tree defines, and the
    # name has to be defined THERE -- not somewhere a lexical search would have
    # reached, because a qualified read does not do a lexical search.
    bare = (sattr[id]["name"] || ndetail[id]).to_s.split("__").last.to_s
    next nil if bare.empty?
    next nil unless const_binders[bare] == const_write_node[bare].length
    at = module_path_of.call(ref[id].fetch("parent", -1))
    next nil unless at
    ws = const_at[at][bare]
    next nil unless ws.length == 1 && runs_always.call(ws.first)
    eval_count.call(ref[ws.first].fetch("value", nil), seen)
  when "LocalVariableReadNode"
    key = [nscope[id], (sattr[id]["name"] || ndetail[id]).to_s]
    ws = local_write_node[key]
    next nil unless ws.length == 1 && local_binders[key] == 1
    next nil unless runs_always.call(ws.first) && pos_before.call(ws.first, id)
    eval_count.call(local_value_node[key].first, seen)
  when "ArrayNode"
    arr[id]["elements"].length
  when "CallNode"
    nm = ndetail[id].to_s
    r = ref[id].fetch("receiver", nil)
    a = ref[id].fetch("arguments", nil)
    args = (a && a >= 0) ? arr[a]["arguments"] : []
    next nil unless %w[+ - * /].include?(nm) && args.length == 1 && r && r >= 0
    l = eval_count.call(r, seen)
    rr = eval_count.call(args[0], seen)
    next nil if l.nil? || rr.nil? || (nm == "/" && rr.zero?)
    l.public_send(nm, rr)
  end
end

#
# THE DECLARED SET AND THE EVALUATED SET ARE REPORTED SEPARATELY, because a
# check that says "29 agree" without saying 29 OF WHAT can be satisfied by
# evaluating one row. Mac review of a9d36ef made this file skip every `fixed:`
# row but one; it answered `fixed counts 1 ... agree 1` and COMPLETE, and the
# suite passed, because the suite was counting rows in the catalog FILE and
# matching the run's number with a regex. Both numbers are named now and the
# suite pins both.
count_fixed_declared = COUNT_ROW.count { |_, nm| nm.start_with?("fixed:") }
count_value_wrong = []
count_value_unevaluated = []
count_value_unsited = []
count_value_agreed = 0
count_verdict = []
COUNT_ROW.each do |(meth, expr), name|
  next unless name.start_with?("fixed:")
  # A row matching no allocation is reported as a DEAD ROW below; saying it
  # twice, once as "the tree cannot evaluate it", would name one fault twice.
  # It is still COUNTED here, so that declared and evaluated add up.
  nodes = allocation_size_node[[meth, expr]]
  if nodes.empty?
    count_value_unsited << "#{meth} #{expr.inspect}"
    count_verdict << ["no-allocation", meth, expr, name, "-"]
    next
  end
  want = Integer(name.split(":", 2)[1], 10)
  got = resolve_one.call(nodes, [])
  if got.nil?
    count_value_unevaluated << "#{meth} #{expr.inspect} is #{name}, and the tree gives no " \
                               "single value for that allocation"
    count_verdict << ["unevaluated", meth, expr, name, "-"]
  elsif got != want
    count_value_wrong << "#{meth} #{expr.inspect} is #{name}, and the tree says #{got}"
    count_verdict << ["contradicted", meth, expr, name, got]
  else
    count_value_agreed += 1
    count_verdict << ["agree", meth, expr, name, got]
  end
end
count_value_seen = count_value_agreed + count_value_wrong.length +
                   count_value_unevaluated.length + count_value_unsited.length

# The receiver of every `[]=` in the tree. An ivar read that appears here is a
# store into that storage, not a read of it.
element_store_receiver = {}
# `[]=` is not the only spelling. A byte buffer is written with `setbyte`, and
# the framebuffer is one: counting only `[]=` made `Renderer@@screen` -- the
# thing every frame is drawn into -- look like a resource Full prepares.
ELEMENT_STORE_NAMES = %w[[]= setbyte].freeze
edges.each do |e|
  next unless ELEMENT_STORE_NAMES.include?(e["name"])
  # `e["rcv"]` is the receiver AFTER the twin mapping, so an instantiated
  # `[]=` -- which carries no ast link of its own -- is counted too. Reading
  # `ref[id]["receiver"]` here instead missed every store in a method Game
  # instantiated from one of its six modules, which is most of them.
  r = e["rcv"]
  element_store_receiver[r] = true if r && r >= 0
end

# AN INDEX OPERATOR WRITE IS AN ELEMENT STORE TOO. `@pl_maxammo[i] *= 2` in
# Game#give_backpack reads and stores through one IndexOperatorWriteNode, and no
# `[]=` edge: counting only the edges made the player's ammo limits a resource
# Full prepares, and the step entry's manifest a read-only borrow the port's
# backpack writes -- which the kernel, not this file, refused. The node's
# receiver is the storage; an instantiated copy of it is marked through its ast
# twin. Every store, of either spelling, is also a STORE SITE -- the definition,
# the receiver node and where -- which the parameter and local rules below read.
INDEX_WRITE_KINDS = %w[IndexOperatorWriteNode IndexOrWriteNode IndexAndWriteNode].freeze
inst_of = Hash.new { |h, k| h[k] = [] }
twin_node.each { |i, a| inst_of[a] << i }
index_op_writes = 0
store_sites = []
kind.each_key do |id|
  next unless INDEX_WRITE_KINDS.include?(kind[id])
  r = ref[id] && ref[id]["receiver"]
  next unless r && r >= 0
  index_op_writes += 1
  ([r] + inst_of[r]).each do |x|
    element_store_receiver[x] = true
    key = scope_cls[nscope[x]]
    store_sites << [key, x, kind[id].sub(/Node\z/, ""), "#{key}, line #{nline[id]}"] if key
  end
end
edges.each do |e|
  next unless ELEMENT_STORE_NAMES.include?(e["name"]) && e["from"] && e["rcv"] && e["rcv"] >= 0
  store_sites << [e["from"], e["rcv"], e["name"], "#{e['file'].to_s.sub(%r{\A.*?/lib/doom/}, 'lib/doom/')}:#{e['line']}"]
end
warn("audit-core: #{index_op_writes} index operator write(s) counted as element stores")

# STORAGE REACHED THROUGH AN ACCESSOR IS STILL STORAGE. `lv.sector_floorheight`
# reads `Level@@sector_floorheight`, and the read happens inside the accessor
# `attr_reader` generated -- a definition with no body, which the walk never
# enters. Counting only the ivar nodes it can see therefore lost every field a
# class exposes that way: measured, all of Level's geometry. 0008 says no field
# may disappear from migration through an unlisted accessor, so a resolved call
# to an accessor is recorded as an access to the storage it names.
accessor_access = []
seen.each_key do |from|
  edges_from[from].each do |e|
    how, cands = resolve(e, defs, by_name, includes, origin_key)
    next if how == "unnarrowed" || cands.length != 1
    callee = cands.first
    info = defs[callee]
    next unless info && info["attr"]
    cls = info["cls"]
    nm = info["name"].to_s
    # An accessor that HANDS BACK an array, whose result is then indexed with
    # `[]=`, is a write to that storage. `lv.sector_floorheight[i] = h` in
    # `move_plane` is the shape, and counting it as a read made the level's
    # geometry look like something Full prepares -- which the count table then
    # had nothing to size, because a prepared value is Full's to size.
    writer = nm.end_with?("=") || element_store_receiver[e["node"]]
    accessor_access << [cls, "@" + nm.sub(/=\z/, ""), writer, from, e["node"]]
  end
end

state = Hash.new do |h, k|
  h[k] = { "w_in" => [], "r_in" => [], "w_out" => 0, "r_out" => 0,
           "domains" => [], "types" => [] }
end
# Every write inside the closure, with the definition and the node that does
# it: what the CORE-writer rule below reads.
write_sites = Hash.new { |h, k| h[k] = [] }
read_sites = Hash.new { |h, k| h[k] = [] }
kind.each_key do |id|
  next unless IVAR_KINDS.include?(kind[id])
  key = scope_cls[nscope[id]]
  next unless key
  cls = defs[key]["cls"]
  name = ndetail[id]
  next if name.nil? || name.empty?
  s = state[[cls, name]]
  # The reader's own type for the storage, joined across its accesses. It is
  # what says whether a field is one value or an array, which the schema's
  # `count` column needs and which nothing else here could tell it. Two
  # different answers are kept as both rather than picked between.
  ty = ntype[id].to_s
  # `strbuf` is the same storage as `string`: upstream's TY_STRBUF is "a
  # mutable string (sp_String *); a storage refinement of TY_STRING". Since
  # the pin move the reader gives it to some reads of a String ivar that a
  # callee mutates (`@exec.run(@jobs, false, @screen)`), and the field's
  # disposition must not depend on which read it was.
  ty = "string" if ty == "strbuf"
  s["types"] |= [ty] unless ty.empty?
  # AN ELEMENT STORE IS A WRITE TO THE STORAGE. `@mobj_x[i] = v` READS the
  # ivar and writes through `[]=`, so counting only InstanceVariableWriteNode
  # made every array in the game look read-only -- measured, it classified
  # `@mobj_x` and `@floorclip` as resources Full prepares, which would have
  # asked Full to prepare the simulation. The receiver of a `[]=` is the
  # storage being written.
  write = kind[id] != "InstanceVariableReadNode" || element_store_receiver[id]
  if seen[key]
    (write ? s["w_in"] : s["r_in"]) << key
    write_sites[[cls, name]] << [key, id] if write
    read_sites[[cls, name]] << [key, id] unless write
    s["domains"] |= domains_of[key]
  else
    write ? s["w_out"] += 1 : s["r_out"] += 1
  end
end
# The accessor reads and writes, recorded against the storage they name. The
# reader gives no type for a field nothing in the walk touches directly, so an
# accessor-only field is typed from the accessor's own result where it has one.
accessor_access.each do |cls, name, writer, from, node|
  write_sites[[cls, name]] << [from, node] if writer
  read_sites[[cls, name]] << [from, node] unless writer
  s = state[[cls, name]]
  (writer ? s["w_in"] : s["r_in"]) << from
  s["domains"] |= domains_of[from]
  s["via_accessor"] = true
end
# --- writes through a parameter -------------------------------------------------
# A BUFFER HANDED TO A METHOD THAT STORES INTO IT IS WRITTEN BY THE CALL. The
# element-store rule above sees `@zonewin.setbyte(...)` and not
# `@wad.zone_window(lnum, off, @zonewin)`, where the store happens inside
# `Wad#zone_window_into` on its parameter `out`. Missing it made the direct
# path's zone window and the job ring, both rewritten every masked column,
# read-only prepared resources of the render entry.
#
# So, over the closure: an element store whose receiver is a REQUIRED PARAMETER
# of the definition it is in marks that parameter written; a resolved call that
# passes a parameter of its caller in a written position marks the caller's
# parameter, to a fixpoint; and where the argument in a written position is an
# instance variable, or a generated reader's result, that field is written by
# the caller. ANY OTHER ARGUMENT -- a local, an expression, a call to more than
# one candidate that writes its parameter, a parameter that is also rebound --
# is named in `unresolved` and fails the run, rather than being guessed at.
params_of = {}
params_plain = {}
kind.each_key do |id|
  next unless kind[id] == "ParametersNode"
  params_of[nscope[id]] = arr[id]["requireds"].map { |p| (sattr[p]["name"] || ndetail[p]).to_s }
  params_plain[nscope[id]] = %w[optionals keywords posts].all? { |k| arr[id][k].empty? } &&
                             !ref[id].key?("rest") && !ref[id].key?("keyword_rest")
end
name_of_node = ->(id) { (sattr[id]["name"] || ndetail[id]).to_s }
args_of = lambda do |node|
  n = ref[node].key?("arguments") ? node : (twin_node[node] || node)
  a = ref[n].fetch("arguments", nil)
  (a && a >= 0) ? arr[a]["arguments"] : []
end
param_written = Hash.new { |h, k| h[k] = Set.new }
arg_write_unresolved = Set.new
arg_writes = Set.new
arg_site = ->(e) { "#{e['file'].to_s.sub(%r{\A.*?/lib/doom/}, 'lib/doom/')}:#{e['line']}" }
# [scope, name, index] when `node` reads a required parameter; nil otherwise.
param_read = lambda do |node|
  next nil unless node && node >= 0 && kind[node] == "LocalVariableReadNode"
  sc = nscope[node]
  nm = name_of_node.call(node)
  i = (params_of[sc] || []).index(nm)
  i && [sc, nm, i]
end
plain_param = ->(sc, nm) { local_binders[[sc, nm]] == 1 && params_plain[sc] }
store_sites.each do |cur, rcv, how, where|
  next unless seen[cur]
  pr = param_read.call(rcv) or next
  if plain_param.call(pr[0], pr[1])
    param_written[cur] << pr[2]
  else
    arg_write_unresolved << "#{how} into parameter #{pr[1]} of #{cur}, which is rebound or " \
                            "beside optional parameters (#{where})"
  end
end
loop do
  grew = false
  seen.each_key do |cur|
    edges_from[cur].each do |e|
      how, cands = resolve(e, defs, by_name, includes, origin_key)
      writing = cands.select { |c| param_written.key?(c) && !param_written[c].empty? }
      next if writing.empty?
      if how == "unnarrowed" || cands.length != 1
        arg_write_unresolved << "#{e['name']} in #{cur} may be #{writing.join(',')}, which writes a " \
                                "parameter, among #{cands.length} candidate(s) (#{arg_site.call(e)})"
        next
      end
      callee = cands.first
      args = args_of.call(e["node"])
      param_written[callee].to_a.each do |i|
        a = args[i]
        at = "argument #{i} of #{cur} -> #{callee} (#{arg_site.call(e)})"
        if a.nil?
          arg_write_unresolved << "no #{at}"
        elsif (pr = param_read.call(a))
          if !plain_param.call(pr[0], pr[1])
            arg_write_unresolved << "#{at} is parameter #{pr[1]}, which is rebound or beside optional parameters"
          elsif param_written[cur].add?(pr[2])
            grew = true
          end
        elsif kind[a] == "InstanceVariableReadNode"
          nm = name_of_node.call(a)
          arg_writes << [defs[cur]["cls"], nm.start_with?("@") ? nm : "@#{nm}", cur, callee]
          write_sites[[defs[cur]["cls"], nm.start_with?("@") ? nm : "@#{nm}"]] << [cur, e["node"]]
        elsif kind[a] == "CallNode"
          e2 = edges_from[cur].find { |x| x["node"] == a || twin_node[x["node"]] == a }
          how2, c2 = e2 ? resolve(e2, defs, by_name, includes, origin_key) : [nil, []]
          info = c2.length == 1 && how2 != "unnarrowed" ? defs[c2.first] : nil
          if info && info["attr"] && !info["name"].to_s.end_with?("=")
            arg_writes << [info["cls"], "@#{info['name']}", cur, callee]
            write_sites[[info["cls"], "@#{info['name']}"]] << [cur, e["node"]]
          else
            arg_write_unresolved << "#{at} is the result of #{e2 ? e2['name'] : 'a call'}, which is not a generated reader"
          end
        else
          arg_write_unresolved << "#{at} is a #{kind[a]}"
        end
      end
    end
  end
  break unless grew
end
# --- writes through a local alias ------------------------------------------------
# A LOCAL BOUND TO STORAGE IS THAT STORAGE. `flags = lv.line_flags` followed by
# `flags[linedef] = flags[linedef] | ML_MAPPED` in Renderer#store_wall_range
# writes Level@@line_flags, and the element-store rule above sees only a local
# receiver: the render entry's manifest said it only reads the line flags, and
# the kernel refused the port's write as a write to a read-only borrow.
#
# So an element store whose receiver is a local that is not a parameter is
# followed to what the local was bound to. Every binding must be a plain write;
# a value that is an instance variable, a generated reader's result, or an
# element read of either is a write to that field; a literal or a builtin that
# makes a new object is fresh storage and writes no field. ANYTHING ELSE -- a
# local bound twice, updated, or bound to another call's result -- is not
# followed and fails the run by name, as an argument that could not be is.
local_write_unresolved = Set.new
local_writes = Set.new
local_field_of = lambda do |v, cur|
  k = kind[v]
  if k == "InstanceVariableReadNode"
    nm = name_of_node.call(v)
    [:field, defs[cur]["cls"], nm.start_with?("@") ? nm : "@#{nm}"]
  elsif %w[ArrayNode StringNode InterpolatedStringNode].include?(k)
    [:fresh]
  elsif k == "CallNode"
    e2 = edges_from[cur].find { |x| x["node"] == v || twin_node[x["node"]] == v }
    how2, c2 = e2 ? resolve(e2, defs, by_name, includes, origin_key) : [nil, []]
    info = c2.length == 1 && how2 != "unnarrowed" ? defs[c2.first] : nil
    builtin = e2 && (c2.empty? || PRIMITIVE_RECEIVERS_W.include?(prov.call(e2)[1]))
    if info && info["attr"] && !info["name"].to_s.end_with?("=")
      [:field, info["cls"], "@#{info['name']}"]
    elsif builtin && e2["name"] == "[]" && e2["rcv"] && e2["rcv"] >= 0
      inner = local_field_of.call(e2["rcv"], cur)
      inner && inner[0] == :field ? inner : nil
    elsif builtin && FRESH_CALLS_W.include?(e2["name"])
      [:fresh]
    elsif e2 && e2["name"] == "new" && e2["rcv_cls"].nil? && c2.empty?
      [:fresh]
    end
  end
end
PRIMITIVE_RECEIVERS_W = %w[int int_array string str_array bool float nil sym].to_set.freeze
FRESH_CALLS_W = %w[new buffer byteslice dup b split pack binread read].freeze
store_sites.each do |cur, r, how, where|
  next unless seen[cur]
  next unless kind[r] == "LocalVariableReadNode"
  next if param_read.call(r)
  sc = nscope[r]
  nm = name_of_node.call(r)
  vals = local_value_node[[sc, nm]]
  at = "#{how} into local #{nm} of #{cur} (#{where})"
  if vals.empty? || local_binders[[sc, nm]] != vals.length
    local_write_unresolved << "#{at}, which is bound other than by plain writes"
    next
  end
  vals.each do |v|
    got = local_field_of.call(v, cur)
    if got.nil?
      local_write_unresolved << "#{at}, bound to a #{kind[v]} this does not follow"
    elsif got[0] == :field
      local_writes << [got[1], got[2], cur]
      write_sites[[got[1], got[2]]] << [cur, r]
    end
  end
end
local_writes.each do |cls, name, cur|
  st = state[[cls, name]]
  st["w_in"] << cur
  st["domains"] |= domains_of[cur]
end
arg_writes.each do |cls, name, cur, _callee|
  st = state[[cls, name]]
  st["w_in"] << cur
  st["domains"] |= domains_of[cur]
end
state.each_value { |s| s["w_in"].uniq!; s["r_in"].uniq! }
touched = state.reject { |_, s| s["w_in"].empty? && s["r_in"].empty? }

role_of = lambda do |s|
  w = !s["w_in"].empty?
  r = !s["r_in"].empty?
  outside = s["w_out"] + s["r_out"] > 0
  if !w && r then "resource"
  elsif w && !r then "output"
  elsif w && r then (outside ? "persistent" : "scratch")
  end
end

# DECISION 0008 TASK 5. Every ivar the closure reaches is one of four things:
# a stored field, an immutable prepared value, an eliminated reference-only
# trace field, or a Full-only value. Most of that is DERIVED -- the reader's
# own type for the storage settles it -- and only the fields it typed `poly`
# need a row in tools/doom/core-fields.tsv, because there the reader resolved
# the expression but not what it produces. A `poly` field with no row is
# unclassified and fails the run.
FIELDS_PATH = opt[:fields] || File.join(TABLES, "core-fields.tsv")
File.exist?(FIELDS_PATH) or abort("audit-core: no field table at #{FIELDS_PATH}")
DISPOSITIONS = %w[stored prepared eliminated full-only].freeze
FIELD_ROW = {}
File.foreach(FIELDS_PATH).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  f.length == 4 or abort("audit-core: #{FIELDS_PATH}:#{i}: #{f.length} column(s), want 4")
  key, disp, elem, why = f
  DISPOSITIONS.include?(disp) or
    abort("audit-core: #{FIELDS_PATH}:#{i}: disposition #{disp.inspect} is not one of #{DISPOSITIONS.join(', ')}")
  why.strip.empty? and abort("audit-core: #{FIELDS_PATH}:#{i}: #{key} needs a reason")
  FIELD_ROW.key?(key) and abort("audit-core: #{FIELDS_PATH}:#{i}: #{key} is listed twice")
  FIELD_ROW[key] = [disp, elem, why]
end

# The derivation. `poly` and `poly_array` are deliberately absent: they are the
# case the table exists for.
derive_disposition = lambda do |types, role|
  ts = types.reject(&:empty?)
  return nil if ts.empty?
  return nil if ts.any? { |x| x == "poly" || x == "poly_array" }
  return ["full-only", "-"] if ts.all? { |x| x.start_with?("obj_") }
  # A byte buffer the closure WRITES is storage CORE owns, not something Full
  # prepared: the framebuffer is a string here, and calling every string
  # prepared made the thing every frame is drawn into a read-only resource.
  if ts.all? { |x| x == "string" || x == "str_array" }
    return role == "resource" ? ["prepared", "u8"] : ["stored", "u8"]
  end
  unless ts.all? { |x| x == "int" || x == "bool" || x == "int_array" }
    return nil
  end
  # THE ROLE DECIDES BETWEEN THE TWO. A numeric field the closure only ever
  # reads is not storage CORE keeps -- it is a value Full prepared before
  # play, which is what `resource` means in 0008's table. Measured: 57 of
  # DOOM's arrays are assigned straight from a prepared table
  # (`Tables.finesine`, `Info.mobj_height`) and never allocated, and calling
  # them stored would have asked Full to allocate something it already has.
  role == "resource" ? ["prepared", "i64"] : ["stored", "i64"]
end

arr_is_array = ->(s) { s["types"].any? { |x| x.end_with?("_array") } }
count_unsited = []
count_unreviewed = []
count_unacquired = []
acquired_used = []
acquired_override = []
acquired_refused = []
used_count_rows = Set.new
field_count = {}
field_fill = {}
field_unclassified = []
field_disposition = {}
state_unclassified = []
state_contradiction = []
# AN ALLOCATION BELONGS TO THE CLASS THAT WROTE IT, or to the classes that
# include the module that did. Keyed by the bare ivar name, as it was, every
# class with an ivar of that name took the allocation: `Random@@mcount` -- one
# counter -- was declared `screen:screenwidth` from `Jobs@@mcount`'s per-column
# array, TiccmdBuilder's four scalars took Demo's `limit:demotics` arrays, and
# Renderer's three psp scalars took the Pspr module's arrays. The reference
# refused all eight for shape, which is how it was found.
alloc_owners = ->(c) { [c] + includes.fetch(c, []) }
touched.each do |(cls, name), s|
  key = "#{cls}@#{name}"
  d = FIELD_ROW[key] || derive_disposition.call(s["types"], role_of.call(s))
  if d.nil?
    field_unclassified << "#{key} (the reader types it " \
                          "#{s['types'].empty? ? 'nothing' : s['types'].sort.join('/')}" \
                          " and #{File.basename(FIELDS_PATH)} has no row)"
  else
    field_disposition[key] = d
  end
  # An array's count comes from its allocation site, through the table. Only a
  # STORED array needs one: a prepared value is Full's to size, and a Full-only
  # reference is not storage at all.
  # ALLOCATED, not "typed as an array". `@screen = Bytes.buffer(@sw * @sh, 0)`
  # is a buffer the reader types `string`, and asking about the type rather
  # than about the allocation gave the framebuffer the scalar's default count
  # of one. Anything something allocates with a size has a count.
  sites = alloc_owners.call(cls).flat_map { |o| allocation_of.fetch([o, name], []) }.uniq
  is_stored_array = d && d.first == "stored" &&
                    (arr_is_array.call(s) || !sites.empty?)
  # A row is DEAD only when no allocation matches it, which is a fact about
  # allocations and not about dispositions: an array that turned out to be
  # prepared is still allocated somewhere, and its row still describes that.
  used_count_rows.merge(sites)
  # THE COUNT IS A FACT ABOUT THE ALLOCATION, NOT ABOUT THE DISPOSITION.
  # It used to be recorded only for a STORED array, so every prepared array
  # fell through to the `fixed:1` default the writer applies at the end --
  # including `Level@blockmap`, which is allocated with a size the catalog
  # maps three rows away as `level:blockmapcells`. tools/doom/emit-schema.rb
  # sizes a prepared field FROM ITS COUNT, so a prepared array left at 1 is a
  # prepared array declared one element long.
  #
  # The REFUSAL still belongs to stored arrays only: an allocated prepared
  # array with no catalog row is reported below as a count nobody measured,
  # and this is only where the ones that DO have a row stop being thrown away.
  unless sites.empty?
    named = sites.map { |pr| COUNT_ROW[pr] }.compact.uniq
    field_count[key] = named unless named.empty?
  end
  # A LENGTH THE ALLOCATION CANNOT GIVE. Usually that is a field the tree
  # never allocates. It is also a field whose allocation counts something
  # ELSE: `Textures@@texdata` is `Array.new(@numtextures, "")`, so the
  # allocation counts 125 ENTRIES, while the schema types the field `u8` and
  # the encoder joins the strings -- 1379328 bytes. The catalog row is right
  # about the allocation and cannot be changed, because `tex_theight` and
  # `tex_widthmask` are allocated from the same expression and really are 125
  # elements long.
  #
  # So an acquired row WINS where there is one, and the run says how many
  # overrode an allocation rather than filling a gap. An override that nobody
  # counted would be a quiet way to replace what the code does.
  if ACQUIRED.key?(key)
    if sites.empty?
      field_count[key] = [ACQUIRED[key]]
      acquired_used << key
    else
      # AN OVERRIDE IS ALLOWED FOR ONE REASON, NOT AS A GENERAL PERMISSION.
      # The first version let any acquired row replace any allocated field's
      # count and merely printed that it had; that is a way to put any number
      # on any field, which is the shape of the inventions this file has been
      # removing.
      #
      # The reason is a REPRESENTATION CONVERSION the allocation cannot
      # express: the reader types the field `str_array`, the schema stores it
      # as bytes, and the encoder joins the strings -- so the allocation's
      # count of ENTRIES is not the field's length in BYTES.
      # `Textures@@texdata` is 125 entries and 1379328 bytes.
      #
      # A field that is not that shape keeps the count its allocation gives,
      # and the row is refused by name. `Game@@mobj_x` is `int_array` stored
      # as i64; no row may resize it.
      joined = s["types"].include?("str_array") &&
               (d && BYTE_ELEMENTS.include?(d[1]))
      if joined
        field_count[key] = [ACQUIRED[key]]
        acquired_used << key
        acquired_override << key
      else
        acquired_refused << "#{key} is allocated and is #{s['types'].sort.join('/')} " \
                            "stored as #{d ? d[1] : '?'}; only a str_array stored as bytes " \
                            "may take its count from #{File.basename(ACQUIRED_PATH)}"
      end
    end
  end
  if is_stored_array
    if sites.empty? && !ACQUIRED.key?(key)
      count_unsited << "#{key} (no `Array.new` or `Bytes.buffer` creates it, and " \
                       "#{File.basename(ACQUIRED_PATH)} has no row for it)"
    elsif !sites.empty?
      missing = sites.reject { |pr| COUNT_ROW[pr] }
      unless missing.empty?
        count_unreviewed << "#{key} is allocated at #{missing.first[0]} with " \
                            "#{missing.first[1].inspect}, which #{File.basename(COUNTS_PATH)} " \
                            "does not map"
      end
    end
  end
  # THE FILL IS DERIVED FROM THE ALLOCATION OR NOT AT ALL. A field with no
  # allocation site gets `UNDERIVED` and not `0`.
  #
  # `0` was invented here for every such field -- 678 of 713 inventory rows
  # printed an initial of 0 and only 371 had an allocation it could have come
  # from. That is the same fabrication `fixed:1` was on the count side, on the
  # neighbouring line, and it matters more: 0008 task 5 is about the state
  # just before the FIRST TICK, after Full initialisation has completed, and
  # that is neither an allocation fill nor a first assignment. A constructor
  # part-way through has `th_alloc = 1` where the initialised game has 97 on
  # E1M1; writing the allocation's zero into the schema and calling it the
  # initial state asserts something nobody measured.
  #
  # What replaces it is NOT a guess from a different place. A field whose
  # initial the code does not fix is either carried as real prepared data or
  # is an open question, and `UNDERIVED` is how it stays visible until one of
  # those is decided per field.
  unless sites.empty?
    fills = alloc_owners.call(cls).flat_map { |o| allocation_fill.fetch([o, name], []) }.uniq
    field_fill[key] = fills.length == 1 ? fills.first : "varies"
  end
  # EVERY ARRAY, not only the stored ones. `emit-schema.rb` sizes a PREPARED
  # field from its count too, so a prepared array with no count is a prepared
  # array declared one element long -- which is what 151 of them were.
  # A BYTE BUFFER IS NOT A SCALAR EITHER. This asked `arr_is_array`, which is
  # true of `int_array` and false of `string` -- and `Bytes.buffer` fields are
  # typed `string`. Twelve of them went straight through at `fixed:1`: the
  # whole IWAD declared one byte long, the colormap, the texture atlas. The
  # question is whether the field HAS a length, not whether the reader spells
  # it with `_array`.
  needs_a_count = arr_is_array.call(s) || s["types"].include?("string")
  if d && %w[stored prepared].include?(d.first) && needs_a_count &&
     sites.empty? && !ACQUIRED.key?(key)
    count_unacquired << "#{key} (#{d.first}, typed #{s['types'].sort.join('/')}, " \
                        "allocated nowhere and not in #{File.basename(ACQUIRED_PATH)})"
  end
  role = role_of.call(s)
  if role.nil?
    state_unclassified << "#{cls}@#{name} (no access at all)"
    next
  end
  owner = OWNER[cls]
  if owner.nil?
    state_unclassified << "#{cls}@#{name} (#{cls} has no row in #{File.basename(STATE_PATH)})"
  elsif owner == "full" && !s["w_in"].empty?
    state_contradiction << "#{cls}@#{name} is declared Full's, but the closure writes it from " \
                           "#{s['w_in'].first}"
  end
end

  # --- cycles -------------------------------------------------------------------
  # Every recursive component of the resolved call graph, which is what decides
  # whether a CORE entry can run on a bounded frame. Tarjan's algorithm, written
  # iteratively: the graph is deep enough that recursing over it to find
  # recursion would be its own joke, and a Ruby stack overflow here would look
  # like an audit failure rather than what it is.
  call_targets = Hash.new { |h, k| h[k] = [] }
  seen.each_key do |k|
    edges_from[k].each do |e|
      how, cands = resolve(e, defs, by_name, includes, origin_key)
      if how != "unnarrowed" && cands.length == 1
        call_targets[k] << [cands.first, e]
      end
      if e["name"] == "new" && e["rcv_cls"]
        init = "#{e['rcv_cls']}#initialize"
        call_targets[k] << [init, e] if defs.key?(init)
      end
    end
  end

  index = {}; low = {}; onstack = {}; stack = []; comps = []; counter = 0
  seen.each_key do |root|
    next if index.key?(root)
    work = [[root, 0]]
    until work.empty?
      v, i = work.last
      if i.zero?
        index[v] = low[v] = counter
        counter += 1
        stack.push(v); onstack[v] = true
      end
      succs = call_targets[v].map(&:first).uniq.select { |w| seen[w] }
      if i < succs.length
        work[-1][1] += 1
        w = succs[i]
        if !index.key?(w)
          work.push([w, 0])
        elsif onstack[w]
          low[v] = [low[v], index[w]].min
        end
      else
        work.pop
        unless work.empty?
          u = work.last[0]
          low[u] = [low[u], low[v]].min
        end
        if low[v] == index[v]
          comp = []
          loop do
            w = stack.pop
            onstack[w] = false
            comp << w
            break if w == v
          end
          comps << comp
        end
      end
    end
  end
  # A component of one is recursive only if it calls itself.
recursive = comps.select do |c|
  c.length > 1 || call_targets[c.first].any? { |tgt, _| tgt == c.first }
end

CYCLES_PATH = opt[:cycles] || File.join(TABLES, "core-cycles.tsv")
File.exist?(CYCLES_PATH) or abort("audit-core: no recursion table at #{CYCLES_PATH}")
CYCLE_ROW = {}
File.foreach(CYCLES_PATH).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  f.length == 4 or abort("audit-core: #{CYCLES_PATH}:#{i}: #{f.length} column(s), want 4")
  anchor, kindname, termination, frame = f
  [termination, frame].each do |x|
    x.strip.empty? and abort("audit-core: #{CYCLES_PATH}:#{i}: #{anchor} needs a termination rule and a frame")
  end
  CYCLE_ROW.key?(anchor) and abort("audit-core: #{CYCLES_PATH}:#{i}: #{anchor} is listed twice")
  CYCLE_ROW[anchor] = [kindname, termination, frame]
end

cycle_unanchored = []
cycle_double = []
anchored = {}
recursive.each do |comp|
  hits = comp.select { |m| CYCLE_ROW.key?(m) }
  if hits.empty?
    cycle_unanchored << "#{comp.length} member(s), including #{comp.sort.first}"
  elsif hits.length > 1
    cycle_double << hits.sort.join(" and ")
  else
    anchored[comp.object_id] = hits.first
  end
end
cycle_unused = CYCLE_ROW.keys.reject { |a| recursive.any? { |c| c.include?(a) } }

# --- configurations -----------------------------------------------------------
# The options the entry accepts, read out of its own tree: a StringNode in
# `main` that begins with a dash and holds no space is one of the literals the
# argument loop compares against. tools/doom/core-configurations.tsv says what
# each varies for the three entries and what tracked command exercises it, and
# the two must be in bijection -- an option with no row, or a row for an option
# the source no longer accepts, fails the run.
CONF_PATH = opt[:configurations] || File.join(TABLES, "core-configurations.tsv")
File.exist?(CONF_PATH) or abort("audit-core: no configuration table at #{CONF_PATH}")
CONF = {}
File.foreach(CONF_PATH).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  f.length == 4 or abort("audit-core: #{CONF_PATH}:#{i}: #{f.length} column(s), want 4")
  optname, dimension, reference, note = f
  optname.start_with?("-") or abort("audit-core: #{CONF_PATH}:#{i}: #{optname.inspect} is not an option")
  (OWNERS + ["resource"]).include?(dimension) or
    abort("audit-core: #{CONF_PATH}:#{i}: dimension #{dimension.inspect} is not one of " \
          "#{(OWNERS + ['resource']).join(', ')}")
  note.strip.empty? and abort("audit-core: #{CONF_PATH}:#{i}: #{optname} needs a note")
  reference.strip.empty? and
    abort("audit-core: #{CONF_PATH}:#{i}: #{optname} needs a reference command or the word NONE")
  CONF.key?(optname) and abort("audit-core: #{CONF_PATH}:#{i}: #{optname} is listed twice")
  CONF[optname] = [dimension, reference, note]
end

# THE ENTRY'S FILE ID, AND NO SECOND ROUTE TO IT. What follows selects the CLI
# option literals DEFINED IN THE ENTRY, so a wrong or missing id does not fail:
# it silently selects nothing and the configuration table then looks complete.
# There was a fallback here reading the ast face's ROOT node, and bb5ea6f removed
# the face that declared it while leaving this use behind -- unreachable on a
# host whose temporary directory is its own realpath, and the only live branch on
# one where it is not. A path this comparison cannot answer is refused with what
# it compared, rather than guessed at from another node.
entry_file_id = files.key(files.values.find { |v| decode_path(v) == SNAP_ENTRY_REAL }) or
  abort("audit-core: no file of the ast face is the entry #{SNAP_ENTRY_REAL}; " \
        "the face names #{files.length} file(s)#{files.values.empty? ? '' : ", the first being #{decode_path(files.values.first)}"}")
cli_options = declared.keys.select do |id|
  declared[id] == "StringNode" && iattr[id]["node_file"] == entry_file_id &&
    (c = sattr[id]["content"]).is_a?(String) && c.length > 1 &&
    c.start_with?("-") && !c.include?(" ")
end.map { |id| sattr[id]["content"] }.uniq.sort

conf_missing = cli_options - CONF.keys
conf_extra = CONF.keys - cli_options

Dir.mkdir(opt[:output]) unless Dir.exist?(opt[:output])
File.open(File.join(opt[:output], "configurations.tsv"), "w") do |io|
  io.puts("# audit-core configurations")
  io.puts("# table\t#{CONF_PATH}")
  io.puts(%w[option dimension reference note].join("\t"))
  cli_options.each do |c|
    d, r, why = CONF[c] || ["UNLISTED", "-", "this option has no row in the configuration table"]
    io.puts([c, d, r, why].join("\t"))
  end
  conf_extra.each do |c|
    d, r, why = CONF[c]
    io.puts([c, d, r, "UNACCEPTED: the entry does not accept this option -- #{why}"].join("\t"))
  end
end

Dir.mkdir(opt[:output]) unless Dir.exist?(opt[:output])
  File.open(File.join(opt[:output], "cycles.tsv"), "w") do |io|
    io.puts("# audit-core cycles")
    io.puts(%w[component size anchor kind member edge-to file line domain].join("\t"))
    recursive.each_with_index do |comp, ci|
      inside = comp.to_set
      comp.sort.each do |m|
        call_targets[m].each do |tgt, e|
          next unless inside.include?(tgt)
          a = anchored[comp.object_id]
          io.puts(["c#{ci}", comp.length, a || "UNANCHORED", a ? CYCLE_ROW[a][0] : "-",
                       m, tgt, e["file"], e["line"], domain_of.call(m)].join("\t"))
        end
      end
    end
  end

# --- what the tree says about an UNDERIVED initial ------------------------------
# 375 fields have no allocation to read a fill from. This records WHAT FORM
# the tree's writes to each of them take. It is information about this
# analysis, not a proof about the field: a shape here says what this pass can
# and cannot read, and never that no derivation exists.
#
# TWO DEFECTS IN THE FIRST VERSION, both found on review, both of them mine.
#
# It collected `InstanceVariableWriteNode` and nothing else, so the 139
# `InstanceVariableOperatorWriteNode`s in the tree were invisible -- including
# `@th_alloc` at game.rb:280, `@mobj_alloc` at 459 and `@gametic` at 896. On
# that reading I reported that the tree holds one literal write for each and
# nothing to tell them apart. The tree holds the updates; the collector
# dropped them. This is the same defect as the local-variable evaluator's, in
# a new collector, after that one had already been corrected -- so the write
# kinds come from `IVAR_KINDS` here rather than from a fresh list.
#
# And it keyed by the BARE ivar name, so every class sharing a name was merged:
# `Game@@validcount` and `Renderer@@validcount` both reported two writes when
# their plain initial assignments are in different classes (game.rb:142,
# render.rb:364). It attributes by (class, ivar) now, through the same
# `scope_cls`/`defs` path the inventory itself uses.
IVAR_WRITE_KINDS = (IVAR_KINDS - ["InstanceVariableReadNode"]).freeze
# WHERE A NODE IS, INCLUDING ONE THAT WAS INSTANTIATED. An instantiated node
# carries no `node_file` of its own -- it is a module's body compiled for the
# class that included it -- so reading `iattr[id]["node_file"]` gave 221 sites
# across 80 fields with an empty path (`update@:651`). `twin_node` is the
# mapping this file already builds from an instantiated node to its ast twin,
# and the twin is in the module's own file, which is the file a reader wants:
# `Game@@ic_n` is updated in mapmove.rb, not in a nameless place.
#
# Repo-relative, because the snapshot directory is this run's and means
# nothing to anyone reading the output.
site_of = lambda do |id|
  f = files[iattr[id]["node_file"]]
  t = twin_node[id]
  f = files[iattr[t]["node_file"]] if (f.nil? || f.empty?) && t
  "#{f.to_s.sub(%r{\A.*?/lib/doom/}, 'lib/doom/')}:#{nline[id]}"
end
ivar_writes = Hash.new { |h, k| h[k] = [] }
kind.each_key do |id|
  next unless IVAR_WRITE_KINDS.include?(kind[id])
  key = scope_cls[nscope[id]]
  next unless key
  cls = defs[key]["cls"]
  name = ndetail[id].to_s
  next if name.empty?
  v = ref[id].fetch("value", nil)
  plain = kind[id] == "InstanceVariableWriteNode"
  lit = plain && v.is_a?(Integer) && v >= 0 &&
        %w[IntegerNode TrueNode FalseNode].include?(kind[v])
  ivar_writes[[cls, name]] << { "kind" => kind[id], "plain" => plain,
                                "literal" => lit, "always" => runs_always.call(id),
                                "at" => site_of.call(id) }
end
fill_shape = Hash.new(0)
fill_rows = []
touched.each_key do |(cls, name)|
  next if field_fill["#{cls}@#{name}"]
  ws = ivar_writes[[cls, name]]
  plains = ws.select { |w| w["plain"] }
  shape =
    if ws.empty? then "no-write"
    elsif ws.any? { |w| !w["plain"] } then "updated-in-place"
    elsif plains.length > 1 then "many-writes"
    elsif !plains.first["literal"] then "not-a-literal"
    elsif !plains.first["always"] then "conditional"
    else "one-literal-unconditional"
    end
  fill_shape[shape] += 1
  fill_rows << [shape, "#{cls}@#{name}", ws.length,
                ws.map { |w| "#{w['plain'] ? 'plain' : 'update'}@#{w['at']}" }.uniq.join(",")]
end
warn("audit-core: underived initials by shape: " +
     fill_shape.sort_by { |_, v| -v }.map { |k, v| "#{k}=#{v}" }.join(", "))

# --- a scratch field is written before it is read -----------------------------
# 0008: scratch bytes are undefined between calls and are checked "through
# initialization/access invariants". The snapshot leaves scratch out, which is
# only right if no read inside an entry can see a value from before the call.
# That is shown here statically, per field and per read, and nothing is taken
# from the role:
#
#   * a read in a definition that writes the field UNCONDITIONALLY -- a plain
#     write whose path to the definition passes only through statements that
#     always run -- on an EARLIER line; or
#   * a read in a definition every one of whose callers in the closure calls it
#     on SELF (an implicit receiver, so the same object's field) and is itself
#     shown to have written the field before the line of that call, by the same
#     two rules. An ENTRY ROOT is never shown -- it is called from outside with
#     whatever the field holds -- and neither is a definition nothing calls.
#
# RECURSION. `cross_bsp_node` calls itself. A call from a definition already
# on the way up is a re-entry on the same object after the field was written:
# every way INTO the cycle is still one of the callers checked, and a cycle
# with no entry from outside would need a root in it, which is not shown. So a
# definition met again on the way up does not fail the read by itself.
#
# A read not shown is reported with its site, and the field is `not-shown`.
callers_of = Hash.new { |h, k| h[k] = [] }
rows.each do |r|
  next unless defs.key?(r[-1])
  callers_of[r[-1]] << [r[0], Integer(r[4], 10), r[6] == "implicit"]
end
# WHEN A WRITE HAS HAPPENED is when its value is done, not where it starts:
# `@bombdamage =\n  @bombdamage + damage` starts on one line and reads the
# field on the next, before the write (Mac review of 7e42637). So a write
# counts from the LAST line of anything inside it, and a read inside its own
# value is never after it. A read on that same last line is not either.
completion_memo = {}
completion_line = lambda do |id|
  next completion_memo[id] if completion_memo.key?(id)
  completion_memo[id] = nil
  own = nline[id].to_s =~ /\A[0-9]+\z/ ? Integer(nline[id], 10) : nil
  kids = ref[id].values.select { |c| c.is_a?(Integer) && c >= 0 } +
         arr[id].values.flatten.select { |c| c.is_a?(Integer) && c >= 0 }
  completion_memo[id] = ([own] + kids.map { |c| completion_line.call(c) }).compact.max
end
first_always_write = {}
scratch_reads = Hash.new { |h, k| h[k] = [] }
kind.each_key do |id|
  next unless IVAR_KINDS.include?(kind[id])
  key = scope_cls[nscope[id]]
  next unless key && seen[key]
  src = twin_node[id] || id
  line = nline[src].to_s
  next unless line =~ /\A[0-9]+\z/
  line = Integer(line, 10)
  fk = [defs[key]["cls"], ndetail[id].to_s]
  if kind[id] == "InstanceVariableWriteNode"
    if runs_always.call(src)
      wk = [key, *fk]
      done = completion_line.call(src)
      first_always_write[wk] = [first_always_write[wk], done].compact.min if done
    end
  else
    # A read, an update (which reads first) or the receiver of a store.
    scratch_reads[fk] << [key, line, site_of.call(id)]
  end
end
root_keys = ROOTS.map { |c, n, _| "#{c}##{n}" }.to_set
written_before = lambda do |d, fk, line, stack|
  w = first_always_write[[d, *fk]]
  next true if w && w < line
  next false if root_keys.include?(d)
  next true if stack.include?(d)
  next false if callers_of[d].empty?
  callers_of[d].all? { |c, cl, self_call| self_call && written_before.call(c, fk, cl, stack + [d]) }
end
scratch_verdicts = []
touched.each do |(cls, name), s|
  next unless role_of.call(s) == "scratch"
  fk = [cls, name]
  unshown = scratch_reads[fk].uniq.reject { |d, line, _| written_before.call(d, fk, line, []) }
  scratch_verdicts << ["#{cls}@#{name}", unshown.empty? ? "written-before-read" : "not-shown",
                       scratch_reads[fk].uniq.length, unshown.map { |d, _, site| "#{d}@#{site}" }.first(3).join(",")]
end
File.open(File.join(opt[:output], "scratch-defined.tsv"), "w") do |io|
  io.puts("# audit-core scratch-defined")
  io.puts("# every scratch field, and whether each read of it inside the closure is shown")
  io.puts("# to follow a write in the same call -- so the value from before the call is")
  io.puts("# never seen. `not-shown` names the reads that are not.")
  io.puts(%w[field verdict reads unshown].join("\t"))
  scratch_verdicts.sort.each { |v| io.puts(v.join("\t")) }
end
warn("audit-core: scratch written before read: #{scratch_verdicts.count { |v| v[1] == 'written-before-read' }} " \
     "of #{scratch_verdicts.length} shown")


# EVERY UNDERIVED INITIAL AND WHY IT IS UNDERIVED, one per line, so the
# decision about each field is made against its own evidence rather than
# against a count.
Dir.mkdir(opt[:output]) unless Dir.exist?(opt[:output])
File.open(File.join(opt[:output], "initials.tsv"), "w") do |io|
  io.puts("# audit-core initials")
  io.puts("# fields with no allocation to read a fill from, and WHAT FORM the")
  io.puts("# tree's writes to each take. A shape here says what this pass can read,")
  io.puts("# NOT that no derivation exists: `many-writes` and `not-a-literal` are")
  io.puts("# facts about this analysis, not proofs about the field.")
  io.puts(%w[shape field writes sites].join("\t"))
  fill_rows.sort_by { |r| [r[0], r[1]] }.each { |r| io.puts(r.join("\t")) }
end

# EVERY DECLARED `fixed:` ROW WITH WHAT HAPPENED TO IT, one per line. A count
# of agreements says nothing about how many rows were looked at; Mac review of
# a9d36ef made this file judge one row out of thirty and the suite still
# passed, because it was comparing the run's number with a regex and counting
# rows in the catalog FILE. With this the declared SET and the judged SET can
# be compared name by name, and the numbers are a summary of it.
Dir.mkdir(opt[:output]) unless Dir.exist?(opt[:output])
File.open(File.join(opt[:output], "fixed-counts.tsv"), "w") do |io|
  io.puts("# audit-core fixed-counts")
  io.puts("# every `fixed:` row in #{File.basename(COUNTS_PATH)} and the tree's answer")
  io.puts(%w[verdict method expression declared tree].join("\t"))
  count_verdict.sort_by { |v| [v[1], v[2]] }.each { |v| io.puts(v.join("\t")) }
end

# --- what Full's setup writes before the first tick ---------------------------
# 0008 task 5 compares the state just before the FIRST TICK, and Full's setup
# is what puts it there. A field's allocation fill is that state only if no
# setup code writes the field after allocating it; `Game.new` spawning the map's
# things is the usual reason it is not. So this walks the calls
# `examples/doom/bin/doom.rb` makes BEFORE its loop -- the configuration the
# comparison runs: no demo, the GPU raster constructed but not opened -- and
# records every field each reached definition writes.
#
# A WRITE MISSED HERE WOULD LET A FILL CLAIM A VALUE SETUP OVERWRITES, so every
# call the walk cannot account for is listed as a gap, not skipped:
#
#   * a call to tree code it cannot follow -- more than one candidate,
#     candidates with no receiver evidence, an allocation with no receiver class;
#   * a BUILTIN whose effect tools/doom/core-builtin-effects.tsv does not list.
#     A call with no tree definition runs no tree code, but that is not
#     evidence it writes nothing: Mac review of 39e4392 put
#     `@setup_probe = Array.new(1, 0); @setup_probe.fill(7)` in Game#initialize
#     and the walk, which skipped every builtin, still listed nothing and
#     reported no gap;
#   * a builtin that MUTATES its receiver, when the walk cannot say which field
#     that receiver is (see `storage_of` below).
#
# The tree has no dynamic dispatch (`send`, `instance_variable_set`,
# `define_method`) for a write to hide behind.
SETUP_ROOTS = %w[
  Wad#initialize Level#initialize TextureNames#initialize Textures#initialize
  Random#initialize Random#clear Game#initialize Wad#bytes_by_name
  Sprites#initialize StatusBar#initialize StatusBar#start Renderer#initialize
  Hud#initialize Renderer#job_mode= GpuRaster#initialize KeyState#initialize
  TiccmdBuilder#initialize KeyScript#initialize DemoWriter#initialize
].freeze
# A run given --roots is on another tree; these roots are DOOM's bin/doom.rb.
if opt[:roots]
  warn("audit-core: setup walk skipped: --roots is not DOOM's tree")
else
  SETUP_ROOTS.each do |k|
    defs.key?(k) or abort("audit-core: setup root #{k} is not defined; the setup roots have drifted")
  end

  # WHAT EACH BUILTIN DOES TO ITS RECEIVER, by name and receiver type (`*` for
  # any). A closed table: a name it does not list is a gap.
  EFFECTS_PATH = opt[:effects] || File.join(TABLES, "core-builtin-effects.tsv")
  File.exist?(EFFECTS_PATH) or abort("audit-core: no builtin effect table at #{EFFECTS_PATH}")
  EFFECTS = {}
  File.foreach(EFFECTS_PATH).with_index(1) do |ln, i|
    next if ln.start_with?("#") || ln.strip.empty?
    f = ln.chomp.split("\t", -1)
    f.length == 4 or abort("audit-core: #{EFFECTS_PATH}:#{i}: #{f.length} column(s), want 4")
    name, recv, eff, why = f
    %w[pure mutates control].include?(eff) or
      abort("audit-core: #{EFFECTS_PATH}:#{i}: effect #{eff.inspect} is not pure, mutates or control")
    why.strip.empty? and abort("audit-core: #{EFFECTS_PATH}:#{i}: #{name} needs a reason")
    EFFECTS.key?([name, recv]) and abort("audit-core: #{EFFECTS_PATH}:#{i}: #{name} on #{recv} is listed twice")
    EFFECTS[[name, recv]] = eff
  end
  effect_of = ->(name, rt) { EFFECTS[[name, rt]] || EFFECTS[[name, "*"]] }

  PRIMITIVE_RECEIVERS = %w[int int_array string str_array bool float nil sym].to_set.freeze
  site_at = ->(e) { "#{e['file'].to_s.sub(%r{\A.*?/lib/doom/}, 'lib/doom/')}:#{e['line']}" }
  setup_seen = {}
  setup_gaps = []
  setup_writes = Hash.new { |h, k| h[k] = [] }
  # Who calls each definition from setup, with the call node, so a parameter can
  # be followed to the argument it was given.
  calls_to = Hash.new { |h, k| h[k] = [] }
  # Writes that change STORAGE (an element store, a mutating builtin) as
  # against rebinding a field to other storage; only the first reaches an alias.
  storage_mutations = Hash.new { |h, k| h[k] = [] }
  mutations = []
  sq = SETUP_ROOTS.dup
  until sq.empty?
    cur = sq.shift
    next if setup_seen[cur]
    setup_seen[cur] = true
    edges_from[cur].each do |e|
      how, cands = resolve(e, defs, by_name, includes, origin_key)
      at = "#{cur} -> #{e['name']} (#{site_at.call(e)})"
      if e["name"] == "new"
        if e["rcv_cls"]
          init = "#{e['rcv_cls']}#initialize"
          if defs.key?(init)
            sq << init
            calls_to[init] << [cur, e]
          end
        else
          setup_gaps << "allocation with no receiver class: #{at}"
        end
        next
      end
      pt = prov.call(e)[1]
      if cands.empty? || PRIMITIVE_RECEIVERS.include?(pt)
        # A BUILTIN. Its effect decides, not its having no tree definition.
        case effect_of.call(e["name"], pt)
        when nil then setup_gaps << "no effect listed for #{e['name']} on #{pt}: #{at}"
        when "mutates" then mutations << [cur, e]
        end
        next
      end
      # EVERY CANDIDATE A GENERATED READER, and the result not stored into: an
      # `attr_reader` has no body, so whichever of them this is, it writes
      # nothing. That is the whole exemption -- a candidate with a body, or a
      # writer, or a read whose result takes `[]=`, stays a gap.
      readers_only = cands.all? { |c| (i = defs[c]) && i["attr"] && !i["name"].to_s.end_with?("=") } &&
                     !element_store_receiver[e["node"]]
      if how == "unnarrowed" && readers_only
        next
      elsif how == "unnarrowed"
        setup_gaps << "no receiver evidence, candidates #{cands.join(',')}: #{at}"
      elsif cands.length == 1
        sq << cands.first
        calls_to[cands.first] << [cur, e]
      else
        setup_gaps << "ambiguous, candidates #{cands.join(',')}: #{at}"
      end
    end
  end

  # THE ROOTS ARE CALLED FROM bin/doom.rb's TOP LEVEL, the scope `-#main`. Each
  # call there to a root is a caller, so a root's parameter is followed to the
  # argument doom.rb passes. `Doom::Game.new` has a constant path for a
  # receiver, whose last segment names the class. Calls after the loop are
  # included too: more callers only make an answer more conservative.
  root_set = SETUP_ROOTS.to_set
  edges_from["-#main"].each do |e|
    if e["name"] == "new" && e["rcv"] && e["rcv"] >= 0 && %w[ConstantPathNode ConstantReadNode].include?(kind[e["rcv"]])
      init = "#{(sattr[e['rcv']]['name'] || ndetail[e['rcv']]).to_s.split(/::|__/).last}#initialize"
      calls_to[init] << ["-#main", e] if root_set.include?(init)
    else
      how, cands = resolve(e, defs, by_name, includes, origin_key)
      calls_to[cands.first] << ["-#main", e] if how != "unnarrowed" && cands.length == 1 && root_set.include?(cands.first)
    end
  end

  # WHICH FIELD A MUTATED RECEIVER IS. Answers are [:field, "Class@@ivar"],
  # [:fresh] for storage made here that no field holds yet, or [:gap, why].
  #
  #   an ivar                        that field, on the class running the code
  #   a generated reader's result    the reader's field
  #   a fresh allocation or literal  no field (assigning it to one later is a
  #                                  write the ivar pass already records)
  #   a local variable               every plain write that binds it in this
  #                                  definition, followed; bound any other way
  #                                  (an update, a block parameter) is a gap
  #   a required parameter           the argument at each setup call site,
  #                                  followed in the caller
  #   anything else                  a gap
  # `params_of`, `params_plain`, `name_of_node` and `args_of` are defined above
  # the state pass, which follows writes through parameters too.
  # WHAT A TREE METHOD RETURNS, when that is readable: the last statement of a
  # body with no `return` anywhere in it. `Bytes.buffer` is
  # `Array.new(n, fill).pack("C*")`, a new string -- which is what lets a
  # buffer it hands back be written without that being a field's write. A body
  # with an explicit `return`, or none to read, answers nothing, and the caller
  # names a gap.
  body_of_scope = {}
  has_return = {}
  kind.each_key do |id|
    if kind[id] == "DefNode"
      b = ref[id]["body"]
      body_of_scope[nscope[b]] = b if b && b >= 0 && kind[b] == "StatementsNode"
    elsif kind[id] == "ReturnNode"
      (has_return[nscope[id]] ||= []) << id
    end
  end
  scopes_of_def = Hash.new { |h, k| h[k] = [] }
  scope_cls.each { |sc, key| scopes_of_def[key] << sc }
  # Every value it can hand back: each `return`'s argument (none is nil) and
  # the last statement, unless that statement is a `return` already or a
  # `raise`, which hands nothing back. A `return` of several values answers
  # nothing, and so does a definition with no single body.
  return_of = lambda do |key|
    scs = scopes_of_def[key].select { |sc| body_of_scope[sc] }
    next nil unless scs.length == 1
    vals = []
    several = false
    (has_return[scs.first] || []).each do |r|
      a = ref[r].fetch("arguments", nil)
      args = a && a >= 0 ? arr[a]["arguments"] : []
      several = true if args.length > 1
      vals << args.first if args.length == 1
    end
    next nil if several
    last = arr[body_of_scope[scs.first]]["body"].last
    unless last.nil? || kind[last] == "ReturnNode" || (kind[last] == "CallNode" && ndetail[last] == "raise")
      vals << last
    end
    vals
  end
  # A literal, or a builtin that makes a new object: arithmetic and bit
  # operators (never `<<`, which returns its receiver), copies, file reads.
  FRESH_KINDS = %w[ArrayNode StringNode InterpolatedStringNode IntegerNode FloatNode
                  HashNode TrueNode FalseNode NilNode SymbolNode].freeze
  FRESH_CALLS = %w[new buffer byteslice dup b split pack + - * / % & | ^ >> -@ ~
                  binread read inspect].freeze
  # NOT `to_s`: String#to_s returns its receiver, so `@a.to_s.setbyte(0, 7)`
  # writes @a (Mac review of b8446d1). A call whose result may be its receiver
  # is not fresh.
  storage_of = lambda do |node, cur, depth|
    next [[:gap, "an alias chain longer than 8 at #{cur}"]] if depth > 8
    k = kind[node]
    if k == "InstanceVariableReadNode"
      [[:field, "#{defs[cur]['cls']}@#{name_of_node.call(node)}"]]
    elsif FRESH_KINDS.include?(k)
      [[:fresh]]
    elsif %w[ConstantReadNode ConstantPathNode].include?(k)
      # A CONSTANT's object is shared by everything that names it. It is not
      # a field, but two fields bound to it share storage through it.
      [[:field, "const:#{(sattr[node]['name'] || ndetail[node]).to_s.split(/::|__/).last}"]]
    elsif %w[IfNode ElseNode ParenthesesNode StatementsNode].include?(k)
      # Whichever branch runs: the last statement of each.
      parts = if k == "StatementsNode" then [arr[node]["body"].last]
              elsif k == "ParenthesesNode" then [ref[node]["body"]]
              elsif k == "ElseNode" then [ref[node]["statements"]]
              else [ref[node]["statements"], ref[node]["subsequent"]]
              end
      parts = parts.compact.select { |p| p >= 0 }
      parts.length == (k == "IfNode" ? 2 : 1) ? parts.flat_map { |p| storage_of.call(p, cur, depth + 1) } :
        [[:gap, "a #{k} without every branch at #{cur}"]]
    elsif k == "CallNode"
      e2 = edges_from[cur].find { |x| x["node"] == node || twin_node[x["node"]] == node }
      if e2.nil?
        [[:gap, "a call result with no edge at #{cur}"]]
      else
        how2, c2 = resolve(e2, defs, by_name, includes, origin_key)
        info = c2.length == 1 && how2 != "unnarrowed" ? defs[c2.first] : nil
        if info && info["attr"] && !info["name"].to_s.end_with?("=")
          [[:field, "#{info['cls']}@@#{info['name']}"]]
        elsif (c2.empty? || PRIMITIVE_RECEIVERS.include?(prov.call(e2)[1])) && e2["name"] == "[]" &&
              e2["rcv"] && e2["rcv"] >= 0
          # AN ELEMENT READ is storage inside the receiver's storage: `elem:` of
          # whatever the receiver is, joined like a field, so two fields holding
          # the same element share it. A fresh receiver's element is fresh.
          storage_of.call(e2["rcv"], cur, depth + 1).map { |t| t[0] == :field ? [:field, "elem:#{t[1]}"] : t }
        elsif (c2.empty? || PRIMITIVE_RECEIVERS.include?(prov.call(e2)[1])) &&
              FRESH_CALLS.include?(e2["name"])
          # A builtin by the walk's own rule -- no tree definition, or a
          # primitive receiver -- that makes a new object.
          [[:fresh]]
        elsif info && (rets = return_of.call(c2.first))
          rets.flat_map { |ret| storage_of.call(ret, c2.first, depth + 1) }
        else
          [[:gap, "storage returned by #{e2['name']} (#{site_at.call(e2)})"]]
        end
      end
    elsif k == "LocalVariableReadNode"
      sc = nscope[node]
      nm = name_of_node.call(node)
      binders = local_binders[[sc, nm]]
      values = local_value_node[[sc, nm]]
      params = params_of[sc] || []
      if params.include?(nm)
        idx = params.index(nm)
        if binders != 1
          [[:gap, "parameter #{nm} of #{cur} is also rebound"]]
        elsif !params_plain[sc]
          [[:gap, "parameter #{nm} of #{cur} beside optional or keyword parameters"]]
        elsif calls_to[cur].empty?
          [[:gap, "parameter #{nm} of #{cur}, which no setup call reaches"]]
        else
          calls_to[cur].flat_map do |caller, ce|
            a = args_of.call(ce["node"])[idx]
            a ? storage_of.call(a, caller, depth + 1) : [[:gap, "no argument #{idx} at #{site_at.call(ce)}"]]
          end
        end
      elsif binders > 0 && values.length == binders
        values.flat_map { |v| storage_of.call(v, cur, depth + 1) }
      else
        [[:gap, "local #{nm} in #{cur} is bound other than by plain writes"]]
      end
    else
      [[:gap, "a #{k} receiver in #{cur}"]]
    end
  end
  mutations.each do |cur, e|
    r = e["rcv"]
    at = "#{cur} -> #{e['name']} (#{site_at.call(e)})"
    if r.nil? || r < 0
      setup_gaps << "#{e['name']} changes a receiver the walk cannot see: #{at}"
      next
    end
    storage_of.call(r, cur, 0).each do |t|
      case t[0]
      when :field
        setup_writes[t[1]] << "#{cur}@#{site_at.call(e)}"
        storage_mutations[t[1]] << "#{cur}@#{site_at.call(e)}"
      when :gap then setup_gaps << "#{e['name']} mutates #{t[1]}: #{at}"
      end
    end
  end

  # NOT THE ALLOCATION ITSELF. `@mobj_x = Array.new(n, 0)` inside `initialize`
  # is a write reached from setup, and counting it made every allocated field
  # "written by setup" -- measured, all 222 comparable fill fields, the 168 that
  # agree with the original included. The allocation is where the fill comes
  # FROM; what matters is a setup write that changes it afterwards. So the write
  # nodes the allocation pass recorded are left out, and nothing else is.
  kind.each_key do |id|
    next unless IVAR_KINDS.include?(kind[id])
    key = scope_cls[nscope[id]]
    next unless key && setup_seen[key]
    name = ndetail[id]
    next if name.nil? || name.empty?
    next unless kind[id] != "InstanceVariableReadNode" || element_store_receiver[id]
    next if allocation_write_ids[id]
    setup_writes["#{defs[key]['cls']}@#{name}"] << "#{key}@#{site_of.call(id)}"
    if kind[id] == "InstanceVariableReadNode"
      storage_mutations["#{defs[key]['cls']}@#{name}"] << "#{key}@#{site_of.call(id)}"
    end
  end
  setup_seen.each_key do |from|
    edges_from[from].each do |e|
      how, cands = resolve(e, defs, by_name, includes, origin_key)
      next if how == "unnarrowed" || cands.length != 1
      info = defs[cands.first]
      next unless info && info["attr"]
      nm = info["name"].to_s
      next unless nm.end_with?("=") || element_store_receiver[e["node"]]
      setup_writes["#{info['cls']}@@#{nm.sub(/=\z/, '')}"] << "#{from}@#{site_at.call(e)}"
      storage_mutations["#{info['cls']}@@#{nm}"] << "#{from}@#{site_at.call(e)}" unless nm.end_with?("=")
    end
  end

  # SHARED STORAGE. `@b = @a` makes two fields one array: a store through @b is
  # a store into @a. Mac review of 1e61b37 added `@a = Array.new(1, 0);
  # @b = @a; @b.fill(7)` to Game#initialize and the walk listed @b alone, while
  # CRuby holds 7 in a[0]. So every rebinding of a field whose storage is
  # mutable -- a plain ivar write, or a generated writer called on an object --
  # is resolved with `storage_of`, the fields it names are joined to it, and a
  # storage mutation of any field is a write to every field it is joined to.
  # A rebinding to storage the walk cannot name is a gap: the field might share
  # it with something no field lists. An integer or boolean field holds no
  # storage and is not joined.
  # By the reader's type at the write: an object reference is not shared
  # STORAGE -- a write through any reference to an object is attributed to
  # that object's class already -- and neither is a number or a flag. Anything
  # else, `poly` and an untyped node included, may be.
  mutable_type = ->(t) { !(t.to_s =~ /\A(int|bool|float|nil|sym|obj_\w+)\z/) }
  alias_parent = {}
  find_alias = lambda do |x|
    alias_parent[x] ||= x
    alias_parent[x] == x ? x : (alias_parent[x] = find_alias.call(alias_parent[x]))
  end
  join_alias = ->(a, b) { ra = find_alias.call(a); rb = find_alias.call(b); alias_parent[ra] = rb unless ra == rb }
  rebind = lambda do |fk, type, value, cur, at|
    # Both the field's type at the write and the value's own: an int produced
    # into a `poly` field is still an int, and holds no storage.
    next unless mutable_type.call(type) && mutable_type.call(ntype[value])
    storage_of.call(value, cur, 0).each do |t|
      case t[0]
      when :field then join_alias.call(fk, t[1])
      when :gap then setup_gaps << "#{fk} may share storage it is bound to: #{t[1]}: #{at}"
      end
    end
  end
  kind.each_key do |id|
    next unless kind[id] == "InstanceVariableWriteNode"
    key = scope_cls[nscope[id]]
    next unless key && setup_seen[key]
    v = ref[id].fetch("value", nil)
    next unless v && v >= 0
    rebind.call("#{defs[key]['cls']}@#{ndetail[id]}", ntype[id], v, key, "#{key}@#{site_of.call(id)}")
  end
  setup_seen.each_key do |from|
    edges_from[from].each do |e|
      how, cands = resolve(e, defs, by_name, includes, origin_key)
      next if how == "unnarrowed" || cands.length != 1
      info = defs[cands.first]
      next unless info && info["attr"] && info["name"].to_s.end_with?("=")
      a = args_of.call(e["node"]).first
      next unless a
      rebind.call("#{info['cls']}@@#{info['name'].to_s.chomp('=')}", ntype[a], a, from, "#{from}@#{site_at.call(e)}")
    end
  end
  alias_members = Hash.new { |h, k| h[k] = [] }
  alias_parent.each_key { |x| alias_members[find_alias.call(x)] << x }
  storage_mutations.each do |fk, sites|
    next unless alias_parent.key?(fk)
    alias_members[find_alias.call(fk)].each do |other|
      next if other == fk || other.start_with?("const:", "elem:")
      sites.uniq.each { |site| setup_writes[other] << "#{site}(through #{fk})" }
    end
  end
  gaps = setup_gaps.uniq.sort
  File.open(File.join(opt[:output], "setup-writes.tsv"), "w") do |io|
    io.puts("# audit-core setup-writes")
    io.puts("# every field a definition reached from Full's setup (bin/doom.rb before its")
    io.puts("# loop) writes, and where. Gaps -- what the walk could not account for --")
    io.puts("# are listed after `#gap`; with any gap, a field absent here is NOT shown to")
    io.puts("# be unwritten by setup. `#complete` is written last and states the counts,")
    io.puts("# so a truncated or partial file does not read as a short list of writes.")
    SETUP_ROOTS.each { |r| io.puts("#root\t#{r}") }
    io.puts(%w[field writers].join("\t"))
    setup_writes.keys.sort.each { |k| io.puts([k, setup_writes[k].uniq.sort.join(",")].join("\t")) }
    gaps.each { |g| io.puts("#gap\t#{g}") }
    io.puts(["#complete", "roots=#{SETUP_ROOTS.length}", "definitions=#{setup_seen.size}",
             "fields=#{setup_writes.size}", "gaps=#{gaps.length}"].join("\t"))
  end
  warn("audit-core: setup reached #{setup_seen.size} definition(s) from #{SETUP_ROOTS.length} root(s), " \
       "writes #{setup_writes.size} field(s), #{gaps.length} gap(s)")
end

Dir.mkdir(opt[:output]) unless Dir.exist?(opt[:output])
File.open(File.join(opt[:output], "local-writes.tsv"), "w") do |io|
  io.puts("# audit-core local-writes")
  io.puts("# Element stores into a local bound to a field (field, definition).")
  io.puts("#field\tdefinition")
  local_writes.to_a.sort.each { |cls, name, cur| io.puts(["#{cls}@#{name}", cur].join("\t")) }
  local_write_unresolved.to_a.sort.each { |u| io.puts("#unresolved\t#{u}") }
  io.puts(["#complete", "writes=#{local_writes.size}", "unresolved=#{local_write_unresolved.size}"].join("\t"))
end
File.open(File.join(opt[:output], "argument-writes.tsv"), "w") do |io|
  io.puts("# audit-core argument-writes")
  io.puts("# every field the closure writes by passing it to a method that stores into")
  io.puts("# that parameter, and what could not be followed. `#complete` is written last.")
  io.puts(%w[field writer callee].join("\t"))
  arg_writes.to_a.sort.each { |cls, name, cur, callee| io.puts(["#{cls}@#{name}", cur, callee].join("\t")) }
  arg_write_unresolved.to_a.sort.each { |u| io.puts("#unresolved\t#{u}") }
  io.puts(["#complete", "writes=#{arg_writes.size}", "unresolved=#{arg_write_unresolved.size}"].join("\t"))
end
File.open(File.join(opt[:output], "state-use.tsv"), "w") do |io|
  io.puts("# audit-core state-use")
  io.puts("# ownership\t#{STATE_PATH}")
  io.puts(%w[class ivar role owner element disposition stored-element count initial domains writers readers writes-outside reads-outside].join("\t"))
  touched.sort_by { |(c, n), _| [c, n] }.each do |(cls, name), s|
    io.puts([cls, name, role_of.call(s) || "UNCLASSIFIED", OWNER[cls] || "UNDECLARED",
             (s["types"].empty? ? "-" : s["types"].sort.join(",")),
             (field_disposition["#{cls}@#{name}"] || ["UNCLASSIFIED"]).first,
             (field_disposition["#{cls}@#{name}"] || ["-", "-"])[1],
             (field_count["#{cls}@#{name}"] || ["fixed:1"]).join("|"),
             (field_fill["#{cls}@#{name}"] || "UNDERIVED"),
             (s["domains"].empty? ? "-" : s["domains"].sort.join(",")),
             (s["w_in"].empty? ? "-" : s["w_in"].sort.join(",")),
             (s["r_in"].empty? ? "-" : s["r_in"].sort.join(",")),
             s["w_out"], s["r_out"]].join("\t"))
  end
end

Dir.mkdir(opt[:output]) unless Dir.exist?(opt[:output])
File.open(File.join(opt[:output], "closure.tsv"), "w") do |io|
  io.puts("# audit-core")
  io.puts("# reader\t#{READER}\t#{reader_id}")
  io.puts("# entry\t#{ENTRY}")
  ledger.each { |l| io.puts("# input\t#{l}") }
  face_binding.each { |l| io.puts("# face\t#{l}") }
  # Each entry's roots, which a root with no call of its own would otherwise
  # leave out of every row: the migration ledger counts them.
  ROOTS.each { |c, n, k| io.puts("# root\t#{c}##{n}\t#{k}") }
  io.puts(%w[from edge callee file line origin receiver domain resolution].join("\t"))
  rows.each { |r| io.puts(r.map { |x| x.nil? ? "" : x.to_s.gsub("\t", " ") }.join("\t")) }
end

warn("audit-core: reader #{READER} #{reader_id}")
warn("audit-core: #{files.size} file(s) opened, #{defs.size} definition(s), #{edges.length} call site(s)")
warn("audit-core: includes " + includes.map { |k, v| "#{k}<-#{v.join(',')}" }.join(" "))
warn("audit-core: reached #{seen.size} definition(s) from #{ROOTS.length} root(s)")
warn("audit-core: per entry " + (ROOT_KINDS + ["given"]).filter_map { |k|
  n = domains_of.count { |_, v| v.include?(k) }
  n.zero? ? nil : "#{k}=#{n}"
}.join(" ") + "; shared by two or more: #{domains_of.count { |_, v| v.length > 1 }}")
warn("audit-core: state #{touched.size} variable(s): " +
     touched.group_by { |_, s| role_of.call(s) }.map { |r, v| "#{r}=#{v.size}" }.sort.join(" "))
warn("audit-core: acquired counts #{ACQUIRED.size} declared, #{acquired_used.length} used " \
     "(#{acquired_override.length} converting entries to joined bytes: " \
     "#{acquired_override.sort.join(', ')})")
# NOT "338 initials determined". 338 fields have a fill READ OFF AN
# ALLOCATION, and that is a different claim: 327 of them are a literal, 4 are
# `varies` because the allocation's elements differ, and 7 are a non-literal
# expression the schema resolves elsewhere. An earlier report of mine said
# 338 initials were settled; it was counting allocations, not answers.
_fills = touched.keys.map { |c, n| field_fill["#{c}@#{n}"] }
warn("audit-core: initials #{_fills.compact.length} read off an allocation " \
     "(literal #{_fills.count { |f| f =~ /\A-?[0-9]+\z/ }}, " \
     "varies #{_fills.count { |f| f == 'varies' }}, " \
     "other #{_fills.compact.count { |f| f != 'varies' && f !~ /\A-?[0-9]+\z/ }}), " \
     "#{_fills.count(&:nil?)} UNDERIVED")
warn("audit-core: fixed counts #{count_fixed_declared} declared, " \
     "#{count_value_agreed + count_value_wrong.length + count_value_unevaluated.length} evaluated " \
     "(agree #{count_value_agreed} contradict #{count_value_wrong.length} " \
     "unevaluated #{count_value_unevaluated.length}), " \
     "#{count_value_unsited.length} matching no allocation")
warn("audit-core: #{recursive.length} recursive component(s), largest #{recursive.map(&:length).max || 0}")
warn("audit-core: #{cli_options.length} configuration(s), #{CONF.count { |_, v| v[1] == 'NONE' }} with no reference command")
warn("audit-core: builtins core=#{problems['core']} obligation=#{problems['obligation']} full-boundary=#{problems['full-boundary']}")
warn("audit-core: ambiguous=#{problems['ambiguous']} unresolved=#{problems['unresolved']} block-edges=#{problems['block']}+#{problems['block-disposed']}disposed instantiated-callnodes=#{instantiated} (via-ast-twin=#{via_twin} without=#{no_twin})")


# --- every CORE output has a CORE writer -----------------------------------------
# The owner's rule of 2026-09-17: every output or persistent field that step or
# render code writes must have a CORE writer -- a migrated definition
# (tools/doom/core-migrated.tsv) that writes it on a path a shipped program
# runs -- unless tools/doom/core-unreached.tsv names the field. A definition
# that is migrated BY NAME does not count for a write it makes only inside a
# configuration's gate: map_plane is migrated and writes span_* only under
# `if @trace`, which its port does not have.
#
# A GATE IS EVALUATED, NOT MATCHED. Under the shipped values -- the renderer's
# `@trace` false, its `@jobmode` 0 (decision 0008, 2026-10-21) -- a write is
# dead when an enclosing `if`/`unless` in a Renderer definition has a
# predicate these values decide and the write is in the branch not taken. A
# predicate built from anything else is not decided, and the write counts as
# live.
MIGRATED_PATH = File.join(TABLES, "core-migrated.tsv")
UNREACHED_PATH = opt[:unreached] || File.join(TABLES, "core-unreached.tsv")
File.exist?(MIGRATED_PATH) or abort("audit-core: no migration table at #{MIGRATED_PATH}")
File.exist?(UNREACHED_PATH) or abort("audit-core: no unreached table at #{UNREACHED_PATH}")
core_defs = Set.new
# an accessor or boundary setter absorbed into fields: Full writes those fields
absorbed_into = Hash.new { |h, k| h[k] = Set.new }
File.foreach(MIGRATED_PATH) do |ln|
  next if ln.start_with?("#") || ln.strip.empty?
  orig, into, = ln.chomp.split("\t", -1)
  names = into.to_s.split(",").map(&:strip)
  names.select { |n| n.start_with?("field:") }.each { |n| absorbed_into[orig] << n.delete_prefix("field:") }
  next if names.any? { |n| n.start_with?("unreached-in-config:", "field:", "eliminated:") }
  core_defs << orig
end
unreached_fields = {}
unreached_reason = {}
File.foreach(UNREACHED_PATH).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  f.length == 4 or abort("audit-core: #{UNREACHED_PATH}:#{i}: #{f.length} column(s), want 4")
  unreached_fields[f[0]] = f[1]
  unreached_reason[f[0]] = f[2]
end
SHIPPED_IVARS = { "@trace" => false, "@jobmode" => 0 }.freeze
GATE_CLASSES = %w[Renderer Random].freeze
# the value of a predicate under the shipped values, or :unknown
gate_value = lambda do |id|
  next :unknown if id.nil? || id < 0
  case kind[id]
  when "InstanceVariableReadNode"
    nm = name_of_node.call(id).to_s
    nm = "@#{nm}" unless nm.start_with?("@")
    SHIPPED_IVARS.fetch(nm, :unknown)
  when "IntegerNode" then (iattr[id]["value"] || ndetail[id]).to_i
  when "TrueNode" then true
  when "FalseNode" then false
  when "ParenthesesNode"
    body = ref[id]["body"]
    body && body >= 0 && kind[body] == "StatementsNode" && arr[body]["body"].length == 1 ?
      gate_value.call(arr[body]["body"][0]) : gate_value.call(body)
  when "AndNode", "OrNode"
    l = gate_value.call(ref[id]["left"])
    r = gate_value.call(ref[id]["right"])
    if kind[id] == "AndNode"
      l == false || r == false ? false : (l == :unknown || r == :unknown ? :unknown : true)
    else
      l == true || r == true ? true : (l == :unknown || r == :unknown ? :unknown : false)
    end
  when "CallNode"
    op = ndetail[id].to_s
    rcv = gate_value.call(ref[id]["receiver"])
    a = ref[id]["arguments"]
    args = (a && a >= 0) ? arr[a]["arguments"] : []
    if op == "!" && args.empty?
      rcv == :unknown ? :unknown : !rcv
    elsif %w[== !=].include?(op) && args.length == 1
      arg = gate_value.call(args[0])
      next :unknown if rcv == :unknown || arg == :unknown
      op == "==" ? rcv == arg : rcv != arg
    else
      :unknown
    end
  else :unknown
  end
end
contains = lambda do |outer, id|
  x = id
  x = parent_of[x] while x && x != outer
  x == outer
end
# true when the node sits in a branch the shipped values do not take
dead_site = lambda do |def_key, id|
  next false unless defs[def_key] && GATE_CLASSES.include?(defs[def_key]["cls"])
  x = id
  dead = false
  while (p = parent_of[x])
    if %w[IfNode UnlessNode].include?(kind[p])
      v = gate_value.call(ref[p]["predicate"])
      unless v == :unknown
        v = !v if kind[p] == "UnlessNode"
        in_then = (st = ref[p]["statements"]) && st >= 0 && contains.call(st, id)
        in_else = (sub = ref[p]["subsequent"] || ref[p]["else_clause"]) && sub >= 0 && contains.call(sub, id)
        dead = true if (in_then && v == false) || (in_else && v == true)
      end
    end
    break if %w[DefNode ProgramNode].include?(kind[p])
    x = p
  end
  dead
end
snake = ->(c) { c.gsub(/([a-z0-9])([A-Z])/, '\\1_\\2').downcase }
writer_missing = []
writer_listed_live = []
reset_contradiction = []
touched.each do |(cls, name), s|
  next unless %w[output persistent].include?(role_of.call(s))
  # storage the schema keeps; an eliminated field has no CORE writer to have
  next unless (field_disposition["#{cls}@#{name}"] || []).first == "stored"
  field = "#{snake.call(cls)}_#{name.delete_prefix('@')}"
  sites = write_sites[[cls, name]].select { |d, _| (domains_of[d] & %w[step render]).any? }
  next if sites.empty?
  # A ROOT ABSORBED INTO THIS FIELD is the boundary: Full writes the field
  # where it called the setter, which is a write the entry sees.
  live = sites.select do |d, n|
    (core_defs.include?(d) && !dead_site.call(d, n)) || absorbed_into[d].include?(field)
  end
  if live.empty?
    writer_missing << "#{field} (#{sites.map(&:first).uniq.sort.join(',')})" unless unreached_fields.key?(field)
  elsif unreached_fields.key?(field)
    writer_listed_live << field
    # A LISTED FIELD WRITTEN ON A SHIPPED PATH is declared unreached in one
    # sense only: RESET ONLY -- its reason says so, every shipped write stores a
    # literal 0, and no shipped path reads it. Anything else is a contradiction.
    zero = live.all? do |_, n|
      kind[n] == "InstanceVariableWriteNode" && (v = ref[n]["value"]) && v >= 0 &&
        kind[v] == "IntegerNode" && (iattr[v]["value"] || ndetail[v]).to_i.zero?
    end
    reads = read_sites[[cls, name]].select do |d, n|
      (domains_of[d] & %w[step render]).any? && core_defs.include?(d) && !dead_site.call(d, n)
    end
    unless unreached_reason[field].to_s.start_with?("RESET ONLY") && zero && reads.empty?
      reset_contradiction << "#{field} (reason says RESET ONLY: #{unreached_reason[field].to_s.start_with?('RESET ONLY')}, " \
                             "every shipped write a literal 0: #{zero}, shipped reads: " \
                             "#{reads.map(&:first).uniq.sort.join(',').then { |x| x.empty? ? 'none' : x }})"
    end
  end
end
warn("audit-core: CORE writers: #{unreached_fields.size} field(s) declared unreached, " \
     "#{writer_listed_live.length} of them reset on a shipped path and read on none (#{writer_listed_live.sort.join(', ')}), " \
     "#{writer_missing.length} written by step or render code with no CORE writer")
fail_why = []
reset_contradiction.empty? or
  fail_why << "#{reset_contradiction.length} field(s) declared unreached and written on a shipped path " \
              "other than as a reset nothing shipped reads: " + reset_contradiction.sort.first(5).join("; ")
writer_missing.empty? or
  fail_why << "#{writer_missing.length} field(s) written by step or render code with no CORE writer " \
              "and no row in #{File.basename(UNREACHED_PATH)}: " + writer_missing.sort.first(5).join("; ")
fail_why << "#{problems['ambiguous']} ambiguous call site(s)" if problems["ambiguous"] > 0
fail_why << "#{problems['unresolved']} unresolved call site(s)" if problems["unresolved"] > 0
fail_why << "#{problems['block']} block edge(s) with no recorded disposition" if problems["block"] > 0
local_write_unresolved.empty? or
  fail_why << "#{local_write_unresolved.size} write(s) through a local that could not be followed: " +
              local_write_unresolved.to_a.sort.first(3).join("; ")
arg_write_unresolved.empty? or
  fail_why << "#{arg_write_unresolved.size} write(s) through an argument that could not be followed: " +
              arg_write_unresolved.to_a.sort.first(3).join("; ")
count_unsited.empty? or
  fail_why << "#{count_unsited.length} stored array(s) with no allocation site: " +
              count_unsited.first(3).join("; ")
count_unreviewed.empty? or
  fail_why << "#{count_unreviewed.length} stored array(s) whose count nobody reviewed: " +
              count_unreviewed.first(3).join("; ")
count_value_seen == count_fixed_declared or
  fail_why << "#{count_fixed_declared} `fixed:` row(s) declared but #{count_value_seen} " \
              "accounted for; every declared row is evaluated or named"
acquired_refused.empty? or
  fail_why << "#{acquired_refused.length} row(s) in #{File.basename(ACQUIRED_PATH)} that may not " \
              "override an allocation: " + acquired_refused.first(3).join("; ")
count_unacquired.empty? or
  fail_why << "#{count_unacquired.length} array(s) with no count at all: " +
              count_unacquired.first(3).join("; ") +
              (count_unacquired.length > 3 ? " (and #{count_unacquired.length - 3} more)" : "")
dead_acquired = ACQUIRED.keys - acquired_used
dead_acquired.empty? or
  fail_why << "#{dead_acquired.length} row(s) in #{File.basename(ACQUIRED_PATH)} naming no " \
              "field that needs one: " + dead_acquired.first(3).join("; ")
count_value_wrong.empty? or
  fail_why << "#{count_value_wrong.length} row(s) in #{File.basename(COUNTS_PATH)} whose number " \
              "the tree contradicts: " + count_value_wrong.first(3).join("; ")
count_value_unevaluated.empty? or
  fail_why << "#{count_value_unevaluated.length} `fixed:` row(s) in #{File.basename(COUNTS_PATH)} " \
              "the tree cannot evaluate: " + count_value_unevaluated.first(3).join("; ")
# A row is dead when NO ALLOCATION IN THE TREE matches it -- not when the
# closure happens not to reach one. `Demo#initialize` allocates its arrays
# whether or not demo playback is in the closure, and a row describing that
# allocation describes something real.
all_allocations = allocation_of.values.flatten(1).uniq
dead_count_rows = COUNT_ROW.keys.reject { |pr| all_allocations.include?(pr) }
dead_count_rows.empty? or
  fail_why << "#{dead_count_rows.length} row(s) in #{File.basename(COUNTS_PATH)} matching no " \
              "allocation: " + dead_count_rows.first(3).map { |m, e| "#{m} #{e.inspect}" }.join("; ")
field_unclassified.empty? or
  fail_why << "#{field_unclassified.length} instance variable(s) with no disposition: " +
              field_unclassified.first(3).join("; ") +
              (field_unclassified.length > 3 ? " (and #{field_unclassified.length - 3} more)" : "")
state_unclassified.empty? or
  fail_why << "#{state_unclassified.length} instance variable(s) with no owner: " +
              state_unclassified.first(3).join("; ") +
              (state_unclassified.length > 3 ? " (and #{state_unclassified.length - 3} more)" : "")
state_contradiction.empty? or
  fail_why << "#{state_contradiction.length} ownership contradiction(s): " + state_contradiction.first(3).join("; ")
cycle_unanchored.empty? or
  fail_why << "#{cycle_unanchored.length} recursive component(s) with no row in #{File.basename(CYCLES_PATH)}: " +
              cycle_unanchored.join("; ")
cycle_double.empty? or
  fail_why << "#{cycle_double.length} recursive component(s) matching two rows: " + cycle_double.join("; ")
cycle_unused.empty? or
  fail_why << "#{cycle_unused.length} row(s) in #{File.basename(CYCLES_PATH)} naming no recursive component: " +
              cycle_unused.join(", ")
conf_missing.empty? or
  fail_why << "#{conf_missing.length} option(s) the entry accepts with no row in " \
              "#{File.basename(CONF_PATH)}: " + conf_missing.join(" ")
conf_extra.empty? or
  fail_why << "#{conf_extra.length} row(s) in #{File.basename(CONF_PATH)} for option(s) the entry " \
              "does not accept: " + conf_extra.join(" ")
receiver_unused.empty? or
  fail_why << "#{receiver_unused.length} row(s) in #{File.basename(RECV_PATH)} matching no call site: " +
              receiver_unused.map { |c, n, r| "#{c} #{n} #{r}" }.join("; ")
missing_kinds = ROOT_KINDS - ROOTS.map { |_, _, k| k }
unless missing_kinds.empty? || opt[:roots_complete]
  fail_why << "the root set has no #{missing_kinds.join(', ')} root, so it is not the migration's closure"
end
if fail_why.empty?
  warn("audit-core: COMPLETE -- closure.tsv, state-use.tsv, cycles.tsv and configurations.tsv written to #{opt[:output]}")
  exit(0)
end
warn("audit-core: INCOMPLETE -- " + fail_why.join("; "))
exit(1)
