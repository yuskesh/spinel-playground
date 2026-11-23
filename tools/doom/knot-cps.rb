# frozen_string_literal: true
#
# tools/doom/knot-cps.rb — the action knot, lowered to a resumable state machine.
#
#   ruby tools/doom/knot-cps.rb [--check]
#
# THE STEP ENTRY'S RECURSIVE KNOT -- the 62 definitions anchored at
# Game#dispatch_action (tools/doom/core-cycles.tsv) -- cannot be compiled as
# written: CORE refuses recursion, and 0008 replaces each recursive component
# with an explicit, preallocated work stack. This tool does that replacement
# ONCE, for all 62, from a direct-style port. The 22 definitions above the knot
# (knot/play.rb, from Game#g_ticker down) are lowered with it: they recurse
# into nothing, but whatever calls the knot from outside must take every
# buffer the knot touches, and inside the machine only the dispatcher does.
#
#   examples/doom/core/knot/*.rb   the knot, written as ordinary step code
#                                  (stepcore.rb's convention), each definition
#                                  `dc_kn_NAME` for `Game#NAME`. Not packed:
#                                  it recurses, and nothing compiles it.
#   examples/doom/core/src/stepknot.rb   what this writes: one step function per
#                                  definition, a dispatcher and a driver.
#
# THE FRAME. Every activation is FRAME cells of the stack buffer `ks`: the
# definition's number, its resume point, then one cell per scalar parameter
# and local, in the order the definition names them. EVERY SCALAR LOCAL LIVES
# IN ITS CELL -- read and written there, never cached -- so a resume finds the
# value the suspension left. Buffers are not locals and not parameters: in the
# direct-style source a buffer is a name the body uses without defining.
#
# EACH STEP FUNCTION TAKES ONLY ITS OWN BUFFERS, and a knot call passes only
# its callee's scalar parameters, because the driver makes the call. The
# kernel's build time grows with the parameters it is handed (measured: 685 s
# for 24835 parameters, 333 s for 13390, with the lines unchanged). Only the
# dispatcher and the driver take the union, and only a ROOT -- a definition no
# other lowered definition calls -- gets a wrapper for callers outside. THE
# DISPATCHER'S ARGUMENTS ARE EMITTED FROM EACH CALLEE'S OWN PARAMETER LIST, so
# a list cannot drift from its callee; tools/doom/buffer-names.rb checks the
# written file for that independently.
#
# THE ONE RESUMPTION DISCIPLINE. A knot call is a statement, `x = dc_kn_f(...)`,
# `dc_kn_f(...)` or `return dc_kn_f(...)`. It writes the callee's frame above its
# own, records where to resume, and returns 1 to the driver, which runs the
# callee. When the callee returns 0 the driver pops it and runs the caller
# again; the caller resumes at the recorded point and finds the callee's value
# in ks[0]. A body is cut into segments at those calls: a loop or a conditional
# that contains one is lowered to segments with explicit resume points, and one
# that does not is written as it stands.
#
# THE SITES ARE COUNTED. tools/doom/knot-sites.tsv lists, from the audit
# (tools/doom/knot-sites.rb), how many call sites each (caller, callee) pair of
# the original has. The direct-
# style source must have exactly those -- a missed call would be a silent wrong
# continuation, which neither the kernel nor any run would report -- and this
# tool refuses to write anything otherwise.
#
# THE STACK. The driver starts at cell 1 (ks[0] holds the last return value)
# and refuses to grow past ks_n with CAPACITY, the only failure CORE has.
require "prism"
require "set"

ROOT = File.expand_path("../..", __dir__)
KNOT_DIR = File.join(ROOT, "examples/doom/core/knot")
OUT = File.join(ROOT, "examples/doom/core/src/stepknot.rb")
SITES = File.join(ROOT, "tools/doom/knot-sites.tsv")
CHECK = ARGV.include?("--check")

def die(msg)
  warn "knot-cps: #{msg}"
  exit 2
end

# ------------------------------------------------------------------ read
Proc_ = Struct.new(:name, :params, :body, :src, :buffers, :scalars, :locals, :id, keyword_init: true)
procs = {}
Dir[File.join(KNOT_DIR, "*.rb")].sort.each do |path|
  src = File.read(path)
  res = Prism.parse(src)
  res.errors.empty? or die("#{path}: #{res.errors.first.message}")
  res.value.statements.body.each do |node|
    next unless node.is_a?(Prism::DefNode)
    name = node.name.to_s
    name.start_with?("dc_kn_") or next
    params = node.parameters ? node.parameters.requireds.map { |p| p.name.to_s } : []
    procs[name] = Proc_.new(name: name, params: params, body: node.body, src: src)
  end
end
procs.empty? and die("no dc_kn_ definitions under #{KNOT_DIR}")
KNOT = procs.keys.to_set

# every node of a subtree
def walk(node, &blk)
  return unless node
  yield node
  node.child_nodes.compact.each { |c| walk(c, &blk) }
end

def knot_call?(node)
  node.is_a?(Prism::CallNode) && node.receiver.nil? && KNOT.include?(node.name.to_s)
end

# A BUFFER IS A FREE NAME. Every parameter of a knot definition is a scalar;
# a name the body uses without defining it (`mobj_x[m]`, `state`, `gx`) is a
# buffer of the step entry, and reaches every step function under that name.
def free_names(body)
  out = Set.new
  walk(body) do |n|
    next unless n.is_a?(Prism::CallNode) && n.receiver.nil? && n.variable_call?
    out << n.name.to_s unless KNOT.include?(n.name.to_s)
  end
  out
end
procs.each_value do |pr|
  pr.buffers = free_names(pr.body)
  pr.scalars = pr.params
  locals = []
  walk(pr.body) do |n|
    case n
    when Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableTargetNode
      nm = n.name.to_s
      locals << nm unless locals.include?(nm) || pr.params.include?(nm)
    end
  end
  pr.buffers.each { |b| locals.include?(b) and die("#{pr.name}: #{b} is a buffer and assigned") }
  pr.locals = pr.scalars + locals
end
procs.values.sort_by(&:name).each_with_index { |pr, i| pr.id = i + 1 }
KB = procs.values.flat_map { |pr| pr.buffers.to_a }.uniq.sort
FRAME = 2 + procs.values.map { |pr| pr.locals.size }.max
MAXARGS = procs.values.map { |pr| pr.scalars.size }.max

# ----------------------------------------------------------------- sites
want = Hash.new(0)
File.foreach(SITES) do |l|
  next if l.start_with?("#") || l.strip.empty?
  a, b, n = l.chomp.split("\t")
  want[[a.delete_prefix("Game#"), b.delete_prefix("Game#")]] = Integer(n)
end
got = Hash.new(0)
procs.each_value do |pr|
  walk(pr.body) do |n|
    got[[pr.name.delete_prefix("dc_kn_"), n.name.to_s.delete_prefix("dc_kn_")]] += 1 if knot_call?(n)
  end
end
missing_defs = want.keys.flatten.uniq.reject { |d| KNOT.include?("dc_kn_#{d}") }
problems = []
problems << "definitions the table names and the source lacks: #{missing_defs.join(' ')}" unless missing_defs.empty?
(want.keys | got.keys).sort.each do |k|
  next if want[k] == got[k]
  problems << "#{k[0]} -> #{k[1]}: the original has #{want[k]} site(s), the source #{got[k]}"
end
unless problems.empty?
  problems.each { |p| warn "knot-cps: #{p}" }
  die("#{problems.size} site mismatch(es); nothing written")
end
if CHECK
  puts "knot-cps: #{procs.size} definitions, #{got.values.sum} sites in #{got.size} pairs, all as the audit counts them"
  exit 0
end

# ----------------------------------------------------------------- lower
class Lowerer
  attr_reader :segments

  def initialize(pr, procs)
    @pr = pr
    @procs = procs
    @cells = pr.locals.each_with_index.to_h { |n, i| [n, i + 2] }
    @segments = []
    @loops = []
    @tmp = 0
  end

  def cell(name) = "ks[fb + #{@cells.fetch(name) { raise "#{@pr.name}: no cell for #{name}" }}]"

  # the source of an expression or plain statement, scalar locals in their cells
  def text(node)
    base = node.location.start_offset
    s = node.slice.dup
    edits = []
    walk(node) do |n|
      case n
      when Prism::LocalVariableReadNode
        edits << [n.location.start_offset - base, n.location.length, n.name.to_s] if @cells.key?(n.name.to_s)
      when Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode
        edits << [n.name_loc.start_offset - base, n.name_loc.length, n.name.to_s] if @cells.key?(n.name.to_s)
      when Prism::LocalVariableTargetNode
        edits << [n.location.start_offset - base, n.location.length, n.name.to_s] if @cells.key?(n.name.to_s)
      end
    end
    edits.sort_by { |o, _, _| -o }.each { |o, l, nm| s[o, l] = cell(nm) }
    s
  end

  def contains_call?(node)
    found = false
    walk(node) { |n| found = true if knot_call?(n) }
    found
  end

  def new_seg
    @segments << +""
    @segments.size - 1
  end

  def lower
    @cur = new_seg
    stmts(@pr.body&.body || [], 1)
    emit("ks[0] = 0", 1)
    emit("return 0", 1)
    # The dispatch tree is the whole body of the driver loop, so a segment's
    # last statement is in value position, where the kernel refuses `next`
    # (it produces nothing). Falling off the tree loops anyway: a trailing
    # jump keeps its `pc =` and ends with a value instead.
    @segments.map { |seg| seg.sub(/^(\s*)next\n\z/) { "#{Regexp.last_match(1)}0\n" } }
  end

  def emit(line, ind)
    @segments[@cur] << ("  " * ind) << line << "\n"
  end

  def goto(target, ind)
    emit("pc = #{target}", ind)
    emit("next", ind)
  end

  def stmts(list, ind)
    list.each { |s| stmt(s, ind) }
  end

  def stmt(node, ind)
    if node.is_a?(Prism::LocalVariableWriteNode) && knot_call?(node.value)
      return call(node.value, node.name.to_s, ind)
    end
    return call(node, nil, ind) if knot_call?(node)
    if node.is_a?(Prism::ReturnNode) && node.arguments && knot_call?(node.arguments.arguments[0])
      call(node.arguments.arguments[0], nil, ind)
      emit("return 0", ind)
      return
    end
    contains_call?(node) && !control?(node) and raise "#{@pr.name}: a knot call inside an expression at line #{node.location.start_line}"
    case node
    when Prism::IfNode, Prism::UnlessNode then contains_call?(node) ? lower_if(node, ind) : keep_if(node, ind)
    when Prism::WhileNode then contains_call?(node) ? lower_while(node, ind) : keep_while(node, ind)
    when Prism::ReturnNode then ret(node, ind)
    when Prism::NextNode then jump(:next, ind)
    when Prism::BreakNode then jump(:break, ind)
    else emit(text(node), ind)
    end
  end

  def control?(node) = [Prism::IfNode, Prism::UnlessNode, Prism::WhileNode].any? { |c| node.is_a?(c) }

  def ret(node, ind)
    v = node.arguments ? text(node.arguments.arguments[0]) : "0"
    emit("ks[0] = #{v}", ind)
    emit("return 0", ind)
  end

  # next/break: the innermost loop decides -- a kept one takes the keyword, a
  # lowered one a jump to its head or its exit
  def jump(kind, ind)
    loop_ = @loops.last or raise "#{@pr.name}: #{kind} outside a loop"
    if loop_[:kept]
      emit(kind.to_s, ind)
    else
      goto(kind == :next ? loop_[:head] : loop_[:exit], ind)
    end
  end

  # a condition is evaluated whole, so it may not suspend: call first, then test
  def pred(node)
    contains_call?(node.predicate) and raise "#{@pr.name}: a knot call in a condition at line #{node.location.start_line}"
    node.is_a?(Prism::UnlessNode) ? "!(#{text(node.predicate)})" : text(node.predicate)
  end

  def keep_if(node, ind)
    emit("if #{pred(node)}", ind)
    stmts(node.statements&.body || [], ind + 1)
    alt = node.consequent
    while alt
      if alt.is_a?(Prism::IfNode)
        emit("elsif #{pred(alt)}", ind)
        stmts(alt.statements&.body || [], ind + 1)
        alt = alt.consequent
      else
        emit("else", ind)
        stmts(alt.statements&.body || [], ind + 1)
        alt = nil
      end
    end
    # a conditional that ends a branch is typed as the branch's value
    emit("end", ind)
    emit("0", ind)
  end

  def keep_while(node, ind)
    emit("while #{text(node.predicate)}", ind)
    @loops << { kept: true }
    stmts(node.statements&.body || [], ind + 1)
    @loops.pop
    emit("end", ind)
  end

  def lower_if(node, ind)
    t = new_seg
    e = new_seg
    j = new_seg
    emit("if #{pred(node)}", ind)
    emit("  pc = #{t}", ind)
    emit("else", ind)
    emit("  pc = #{e}", ind)
    emit("end", ind)
    emit("next", ind)
    @cur = t
    stmts(node.statements&.body || [], 1)
    goto(j, 1)
    @cur = e
    alt = node.consequent
    if alt.is_a?(Prism::IfNode)
      stmt(alt, 1)
    elsif alt
      stmts(alt.statements&.body || [], 1)
    end
    goto(j, 1)
    @cur = j
  end

  def lower_while(node, ind)
    h = new_seg
    b = new_seg
    x = new_seg
    goto(h, ind)
    @cur = h
    emit("if #{pred(node)}", 1)
    emit("  pc = #{b}", 1)
    emit("else", 1)
    emit("  pc = #{x}", 1)
    emit("end", 1)
    emit("next", 1)
    @cur = b
    @loops << { kept: false, head: h, exit: x }
    stmts(node.statements&.body || [], 1)
    @loops.pop
    goto(h, 1)
    @cur = x
  end

  # a knot call: the callee's frame, the resume point, and the value on resume
  def call(node, target, ind)
    callee = @procs.fetch(node.name.to_s)
    args = node.arguments ? node.arguments.arguments : []
    args.size == callee.params.size or raise "#{@pr.name}: #{callee.name} takes #{callee.params.size} arguments"
    emit("if fb + #{2 * FRAME} > ks_n", ind)
    emit("  core_fail(:capacity)", ind)
    emit("end", ind)
    emit("ks[fb + #{FRAME}] = #{callee.id}", ind)
    emit("ks[fb + #{FRAME + 1}] = 0", ind)
    callee.params.each_with_index do |_, i|
      emit("ks[fb + #{FRAME + 2 + i}] = #{text(args[i])}", ind)
    end
    r = new_seg
    emit("ks[fb + 1] = #{r}", ind)
    emit("return 1", ind)
    @cur = r
    emit("#{cell(target)} = ks[0]", 1) if target
  end
end

# a range tree over integer keys, each leaf a line
def tree(keys, ind, var, &leaf)
  sp = "  " * ind
  return "#{sp}#{leaf.call(keys[0])}\n" if keys.size == 1
  mid = keys[keys.size / 2 - 1]
  "#{sp}if #{var} <= #{mid}\n" + tree(keys[0, keys.size / 2], ind + 1, var, &leaf) +
    "#{sp}else\n" + tree(keys[keys.size / 2..], ind + 1, var, &leaf) + "#{sp}end\n"
end

# a parameter list, wrapped
def plist(names, col)
  lines = []
  cur = +""
  names.each_with_index do |n, i|
    piece = n + (i == names.size - 1 ? "" : ", ")
    if col + (cur + piece).rstrip.size > 116 && !cur.empty?
      lines << cur.rstrip
      cur = +""
    end
    cur << piece
  end
  lines << cur
  lines.join("\n" + " " * col)
end
own = ->(pr) { pr.buffers.to_a.sort }
called = procs.values.flat_map do |pr|
  found = []
  walk(pr.body) { |n| found << n.name.to_s if knot_call?(n) }
  found
end.uniq
roots = procs.values.reject { |pr| called.include?(pr.name) }
roots.empty? and die("no root: every lowered definition is called by another")
out = +<<~HEAD
  # examples/doom/core/src/stepknot.rb — GENERATED by tools/doom/knot-cps.rb from
  # examples/doom/core/knot/. Do not edit: edit the direct-style source and run it.
  #
  # GPL-derived, as the direct-style source it is generated from. See
  # ../NOTICE.md and ../sources.tsv.
  #
  # The action knot as a resumable state machine; the header of
  # tools/doom/knot-cps.rb says how. #{procs.size} definitions, a frame of #{FRAME} cells.

  KN_FRAME = #{FRAME}

HEAD
procs.values.sort_by(&:id).each do |pr|
  segs = Lowerer.new(pr, procs).lower
  out << "# Game##{pr.name.delete_prefix('dc_kn_')}\n"
  head = "def dc_st_kp_#{pr.name.delete_prefix('dc_kn_')}("
  out << head << plist(own.call(pr) + %w[ks ks_n fb], head.size) << ")\n"
  out << "  pc = ks[fb + 1]\n"
  out << "  while true\n"
  out << tree((0...segs.size).to_a, 2, "pc") { |k| "k#{k}" }.gsub(/^(\s*)k(\d+)$/) do
    ind = Regexp.last_match(1)
    segs[Regexp.last_match(2).to_i].gsub(/^/, ind)
  end
  out << "  end\n  0\nend\n\n"
end
ids = procs.values.map(&:id).sort
by_id = procs.values.to_h { |p| [p.id, p] }
out << "# one step of the frame at fb\n"
out << "def dc_st_knot_step(" << plist(KB + %w[ks ks_n fb], 22) << ")\n  p = ks[fb]\n"
out << tree(ids, 1, "p") do |i|
  call = "dc_st_kp_#{by_id[i].name.delete_prefix('dc_kn_')}("
  depth = 2 + Math.log2([ids.size, 2].max).ceil * 2
  call + plist(own.call(by_id[i]) + %w[ks ks_n fb], depth + call.size) + ")"
end
out << "end\n\n"
args = (0...MAXARGS).map { |i| "a#{i}" }
out << "# run a knot definition to its end; its value\n"
out << "def dc_st_knot_run(" << plist(KB + %w[ks ks_n pid] + args, 21) << ")\n"
out << "  if 1 + #{FRAME} > ks_n\n    core_fail(:capacity)\n  end\n"
out << "  ks[1] = pid\n  ks[2] = 0\n"
args.each_with_index { |a, i| out << "  ks[#{3 + i}] = #{a}\n" }
out << "  sp = 1\n  while sp > 0\n    fb = 1 + (sp - 1) * #{FRAME}\n"
out << "    code = dc_st_knot_step(" << plist(KB + %w[ks ks_n fb], 28) << ")\n"
out << "    if code == 0\n      sp -= 1\n    else\n      sp += 1\n    end\n  end\n  ks[0]\nend\n\n"
roots.sort_by(&:id).each do |pr|
  short = pr.name.delete_prefix("dc_kn_")
  pad = (0...MAXARGS).map { |i| i < pr.scalars.size ? pr.scalars[i] : "0" }
  head = "def dc_st_#{short}("
  out << "# the machine's root: Game##{short} run to its end\n"
  out << head << plist(KB + %w[ks ks_n] + pr.scalars, head.size) << ")\n"
  out << "  dc_st_knot_run(" << plist(KB + %w[ks ks_n] + [pr.id.to_s] + pad, 17) << ")\nend\n\n"
end
# EVERY PUSH IS CHECKED -- BY CONSTRUCTION, AND THEN BY READING WHAT WAS
# WRITTEN. The capacity check and the push are emitted together, from one place
# (`call`, above), so a push without a check cannot be written. That is the
# argument; this is the evidence, taken from the generated text rather than
# from the generator's shape, because the argument is what decision 0008's
# capacity contract rests on: no push may write past the declared capacity.
#
# A push is `ks[fb + FRAME] = <callee>`, the first cell of the new frame. The
# machine's entry (`dc_st_knot_run`) writes the FIRST frame at cell 1 and is
# checked the same way, against `1 + FRAME`.
pushes = 0
unchecked = []
lines = out.lines
lines.each_with_index do |l, i|
  next unless l =~ /\A\s*ks\[fb \+ #{FRAME}\] = /
  pushes += 1
  before = lines[[0, i - 3].max...i].join
  unchecked << (i + 1) unless before =~ /if fb \+ #{2 * FRAME} > ks_n\n\s*core_fail\(:capacity\)\n\s*end\n/
end
entry = out =~ /def dc_st_knot_run\(.*?\n  if 1 \+ #{FRAME} > ks_n\n    core_fail\(:capacity\)\n  end\n  ks\[1\] = pid\n/m
unless unchecked.empty? && entry
  unchecked.each { |n| warn "knot-cps: the push at line #{n} of the generated file has no capacity check before it" }
  warn "knot-cps: the machine's entry does not check the capacity before its first frame" unless entry
  die("#{unchecked.size + (entry ? 0 : 1)} unchecked push(es); nothing written")
end
File.write(OUT, out)
puts "knot-cps: #{pushes} push(es), each preceded by its capacity check, and the entry's first frame checked"
puts "knot-cps: #{procs.size} definitions, #{got.values.sum} sites, frame #{FRAME}, #{KB.size} buffers, " \
     "root(s) #{roots.map { |r| r.name.delete_prefix('dc_kn_') }.join(' ')} -> #{OUT}"
