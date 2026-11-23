# frozen_string_literal: true
#
# tools/doom/core-store-widths.rb — decision 0018's static evidence: what the
# source says about the width of every value stored into an entry's buffer.
#
#   ruby tools/doom/core-store-widths.rb [--root DIR] --output FILE
#
# Every buffer the three entries take (examples/doom/core/entries/fields.tsv,
# without core_state and the derived index tables) gets one row: each store to
# it in the units the entries are packed from (entries/units.tsv), with the
# store's right-hand side classified, and whether those stores BOUND the field.
#
# THE CLASSES, of a store `name[...] = v` (a whole-line right-hand side):
#   i32    v is fixed_to_i32(...), fixed_mul(...) or fixed_div(...), each of
#          which ends in the int32 truncation (examples/doom/core/src/fixed.rb),
#          or one of decision 0022's word intrinsics other than a comparison
#          (core_w32_add, _sub, _mul, _neg, core_u32_shr, core_fixed_mul,
#          core_fixed_div), each of which answers the low 32 bits of its exact
#          result as a signed i32 (tools/core/intrinsics.rb)
#   u32    v is fixed_bam(...), or ends in `& 0xffffffff` or `& <PREFIX>_M32`
#   const  v is an integer literal, or a constant the units assign one
#   copy   v is another buffer's element: its range is that buffer's
#   other  anything else, including every op-assign (`+=`, `|=` ...) and a
#          right-hand side that continues on the next line
#
# A FIELD IS STATIC only when the stores this scan sees are ALL the stores there
# are, and each of them is i32, u32 or const. The scan sees a store by the
# buffer's name, which is the field's own parameter name because
# tools/doom/buffer-names.rb requires every step and render-spine call to hand
# a buffer on under it. So a field is NOT static, whatever its stores, when it
# can be written under another name or by a builtin:
#   * it is an argument of dc_draw_statusbar or dc_draw_hud in the entries
#     (doomentry.rb), the two units that predate that convention;
#   * its parameter is renamed at a call (tools/doom/buffer-roles.tsv);
#   * the units call a mutating builtin on it (`name.fill(...)`, `name << v`,
#     tools/doom/core-builtin-effects.tsv's `mutates` rows).
# A static field's range is the union of its stores' ranges (i32 is
# -2^31..2^31-1, u32 is 0..2^32-1, a constant is itself). The value Full
# prepares before the first tic is not a store; core-widths.rb requires it to
# lie inside that range, from the measurement.
#
# Nothing here is a proof that the scan is complete for code outside the units,
# and it does not need to be: decision 0018 protects every narrowed store with
# the ARITHMETIC failure, and a field this scan cannot bound is measured.

require "optparse"
require "set"

ROOT_DEFAULT = File.expand_path("../..", __dir__)
opt = { root: ROOT_DEFAULT }
OptionParser.new do |o|
  o.on("--root DIR") { |v| opt[:root] = v }
  o.on("--output FILE") { |v| opt[:output] = v }
end.parse!
opt[:output] or abort("usage: core-store-widths.rb [--root DIR] --output FILE")

I32 = [-(1 << 31), (1 << 31) - 1].freeze
U32 = [0, (1 << 32) - 1].freeze
CORE = File.join(opt[:root], "examples/doom/core")

def rows(path)
  File.readlines(path).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t", -1) }
end

units = rows(File.join(CORE, "entries/units.tsv")).map(&:first)
src = units.to_h { |u| [u, File.readlines(File.join(CORE, "src", u))] }

# The fields, and the parameter names each is taken under. Two entries may take
# two fields under one name (`finesine` is game_finesine to the step entry and
# renderer_finesine to the render entry); a store under that name is then
# attributed to both, which can only make a field less static.
fields = {}
by_name = Hash.new { |h, k| h[k] = [] }
rows(File.join(CORE, "entries/fields.tsv")).each do |_e, param, field, element, _mode|
  next if field == "core_state" || field.start_with?("derived:")
  fields[field] ||= { element: element, names: Set.new }
  fields[field][:names] << param
  by_name[param] << field unless by_name[param].include?(field)
end

# The integer constants the units define, for `const` stores.
consts = {}
src.each_value do |lines|
  lines.each do |l|
    consts[$1] = Integer($2.delete("_")) if l =~ /\A([A-Z][A-Z0-9_]*)\s*=\s*(-?(?:0x[0-9a-fA-F_]+|\d[\d_]*))\s*(?:#.*)?\z/
  end
end

# The names that make a field unbounded by this scan.
loose = Set.new
entry = src.fetch("doomentry.rb").join
%w[dc_draw_statusbar dc_draw_hud].each do |fn|
  entry.scan(/#{fn}\(([^)]*)\)/m) { |(args)| args.split(",").each { |a| loose << a.strip if a.strip =~ /\A[a-z_][a-z0-9_]*\z/ } }
end
rows(File.join(opt[:root], "tools/doom/buffer-roles.tsv")).each { |r| loose << r[3] if r[3] }
mutators = rows(File.join(opt[:root], "tools/doom/core-builtin-effects.tsv"))
           .select { |r| r[2] == "mutates" && r[0] =~ /\A[a-z_]+\z/ }.map(&:first).uniq
src.each_value do |lines|
  lines.each do |l|
    l.scan(/(?<![\w.])([a-z_][a-z0-9_]*)\.(#{mutators.join('|')})\b/) { |n, _| loose << n }
    l.scan(/(?<![\w.])([a-z_][a-z0-9_]*)\s*<<(?!=)/) { |(n)| loose << n if by_name.key?(n) && !(l =~ /\b#{n}\s*<<\s*\d/) }
  end
end

BAL = /\((?:[^()]|\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))*\)/
def classify(rhs, op, consts)
  return ["other", nil] unless op == "="
  r = rhs.sub(/\s+#.*\z/, "").strip
  return ["i32", I32] if r =~ /\A(?:fixed_to_i32|fixed_mul|fixed_div|core_w32_(?:add|sub|mul|neg)|core_u32_shr|core_fixed_(?:mul|div))#{BAL}\z/
  return ["u32", U32] if r =~ /\Afixed_bam#{BAL}\z/ || r =~ /&\s*(?:0xffffffff|[A-Z][A-Z0-9]*_M32)\s*\z/
  return ["const", [Integer(r), Integer(r)]] if r =~ /\A-?\d+\z/
  return ["const", [consts[r], consts[r]]] if consts.key?(r)
  return ["copy", nil] if r =~ /\A[a-z_][a-z0-9_]*\[[^\[\]]*\]\z/
  ["other", nil]
end

sites = Hash.new { |h, k| h[k] = [] }
src.each do |u, lines|
  lines.each_with_index do |line, i|
    next if line.lstrip.start_with?("#")
    line.scan(/(?<![\w.])([a-z_][a-z0-9_]*)\[[^\[\]]*(?:\[[^\[\]]*\][^\[\]]*)*\]\s*(=|[-+*\/%|&^]=|<<=|>>=)(?!=)(.*)/) do |name, op, rhs|
      next unless by_name.key?(name)
      kind, range = classify(rhs, op, consts)
      by_name[name].each { |f| sites[f] << [kind, range, "#{u}:#{i + 1}"] }
    end
  end
end

File.open(opt[:output], "w") do |io|
  io.puts "# Generated by tools/doom/core-store-widths.rb -- the stores the units make to each entry buffer."
  io.puts "# static: yes when every store is i32, u32 or const and the field cannot be written under another"
  io.puts "# name; min and max are then the union of the stores' ranges, and sites lists every store."
  io.puts "#field\telement\tstores\ti32\tu32\tconst\tcopy\tother\tstatic\tmin\tmax\tsites"
  fields.keys.sort.each do |f|
    s = sites[f]
    c = Hash.new(0)
    s.each { |k, _, _| c[k] += 1 }
    why = if fields[f][:names].any? { |n| loose.include?(n) } then "no:other-name"
          elsif s.empty? then "no:no-store"
          elsif s.any? { |k, _, _| !%w[i32 u32 const].include?(k) } then "no:#{s.find { |k, _, _| !%w[i32 u32 const].include?(k) }[0]}"
          else "yes"
          end
    mn = mx = "-"
    if why == "yes"
      mn = s.map { |_, r, _| r[0] }.min
      mx = s.map { |_, r, _| r[1] }.max
    end
    io.puts [f, fields[f][:element], s.size, c["i32"], c["u32"], c["const"], c["copy"], c["other"], why, mn, mx,
             s.map { |_, _, w| w }.join(",")].join("\t")
  end
end
n = fields.size
st = fields.keys.count { |f| (s = sites[f]).any? && fields[f][:names].none? { |x| loose.include?(x) } && s.all? { |k, _, _| %w[i32 u32 const].include?(k) } }
puts "core-store-widths: #{n} buffer(s), #{sites.values.sum(&:size)} store(s), #{st} static, #{loose.size} name(s) written otherwise -> #{opt[:output]}"
