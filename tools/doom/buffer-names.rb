# frozen_string_literal: true
#
# tools/doom/buffer-names.rb — every buffer is handed on under its own name.
#
#   ruby tools/doom/buffer-names.rb [FILE...]
#
# THE STEP CONVENTION PASSES A BUFFER UNDER ITS FIELD'S NAME, at every call:
# `mobj_x` is `mobj_x` in the caller and in the callee. The step definitions
# take long buffer lists that differ from callee to callee, and nearly every
# buffer is an i64 pointer, so an argument list that drifted out of order --
# `mobj_y` where the callee reads `mobj_x` -- is not a type conflict the kernel
# could refuse: it is a wrong field, silently. This refuses it instead: at
# every call to a step definition (`dc_st_*`), an argument in a position where
# the callee takes a buffer must be a bare name, and that name must be the
# callee's parameter name.
#
# A parameter is a buffer when the callee's body indexes it or hands it on in a
# buffer position of its own callee (the fixed point tests/doom-core/stepall.rb
# computes), or when it is `state` or an index table. The input port's calls
# (`dc_in_*`) are checked the same way, and so are the entries' calls to those
# three families (examples/doom/core/src/doomentry.rb), whose renamed arguments
# are roles pinned in buffer-roles.tsv. NOT CHECKED: calls to the units written
# before the convention -- `dc_draw_statusbar` and `dc_draw_hud` name their
# buffers otherwise -- where the entries' `@name` arguments are
# tools/doom/core-entries.rb's explicit bindings, and render-diff.rb is what
# compares their result. With no FILE, it reads
# examples/doom/core/src/{step,rv}*.rb.
require "prism"
require "set"

ROOT = File.expand_path("../..", __dir__)
files = ARGV.empty? ? Dir[File.join(ROOT, "examples/doom/core/src/{step,rv}*.rb")].sort : ARGV
ROLES = File.readlines(File.join(ROOT, "tools/doom/buffer-roles.tsv"))
            .reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t") }.to_set
defs = {}
calls = []
ordinal = Hash.new(0)
walk = lambda do |node, owner, &blk|
  next unless node
  blk.call(node, owner)
  node.child_nodes.compact.each { |c| walk.call(c, owner, &blk) }
end
files.each do |f|
  Prism.parse(File.read(f)).value.statements.body.each do |d|
    next unless d.is_a?(Prism::DefNode) && d.name.to_s.start_with?("dc_st_", "dc_sp_", "dc_rv_", "dc_in_", "doom_core_")
    params = d.parameters ? d.parameters.requireds.map { |p| p.name.to_s } : []
    indexed = []
    walk.call(d.body, d.name.to_s) do |n, owner|
      next unless n.is_a?(Prism::CallNode)
      if %i[[] []=].include?(n.name) && n.receiver.is_a?(Prism::LocalVariableReadNode)
        indexed << n.receiver.name.to_s
      elsif n.receiver.nil? && n.name.to_s.start_with?("dc_st_", "dc_rv_", "dc_in_")
        args = n.arguments ? n.arguments.arguments : []
        ordinal[[owner, n.name.to_s]] += 1
        calls << [f, n.location.start_line, owner, n.name.to_s, args, "#{owner}##{ordinal[[owner, n.name.to_s]]}"]
      end
    end
    defs[d.name.to_s] = { entry: d.name.to_s.start_with?("dc_sp_", "doom_core_"), params: params,
                          buf: params.to_h { |p| [p, %w[state gx rx xi].include?(p) || indexed.include?(p)] } }
  end
end
loop do
  changed = false
  calls.each do |_, _, owner, callee, args, _|
    next unless defs[callee] && defs[owner]
    args.each_with_index do |a, i|
      cp = defs[callee][:params][i]
      next unless cp && defs[callee][:buf][cp] && a.is_a?(Prism::LocalVariableReadNode)
      nm = a.name.to_s
      next if !defs[owner][:buf].key?(nm) || defs[owner][:buf][nm]
      defs[owner][:buf][nm] = true
      changed = true
    end
  end
  break unless changed
end
bad = []
checked = 0
roled = 0
calls.each do |f, line, _, callee, args, site|
  d = defs[callee] or next
  next if d[:entry]
  if args.size != d[:params].size
    bad << "#{File.basename(f)}:#{line}: #{callee} takes #{d[:params].size} arguments, given #{args.size}"
    next
  end
  args.each_with_index do |a, i|
    cp = d[:params][i]
    next unless d[:buf][cp]
    checked += 1
    got = a.is_a?(Prism::LocalVariableReadNode) || (a.is_a?(Prism::CallNode) && a.variable_call?) ? a.name.to_s : a.slice
    next if got == cp
    if ROLES.include?([callee, cp, site, got])
      roled += 1
      next
    end
    bad << "#{File.basename(f)}:#{line}: #{callee} argument #{i + 1} is `#{got}`, its buffer parameter is `#{cp}`"
  end
end
bad.each { |b| warn "buffer-names: #{b}" }
puts "buffer-names: #{calls.size} call(s) to #{defs.size} definition(s), #{checked} buffer argument(s), " \
     "#{roled} bound by role, #{bad.size} misnamed"
exit(bad.empty? ? 0 : 1)
