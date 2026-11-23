# frozen_string_literal: true
#
# tests/doom-core/initial-sets.rb — where each field's opening value is compared.
#
#   ruby tests/doom-core/initial-sets.rb SNAPSHOT STORED PREPARED SCHEMA INVENTORY
#                                        SETUP_WRITES HELD AUDIT_ERR SHAPEFIELDS WAD
#
# A stored field whose pre-tick value Full carries -- UNDERIVED, or written by
# Full's setup after allocating it -- moves from the stored lane (compared
# against its fill) to the prepared lane (compared against Full's value). That
# is only a move if it loses nothing and follows the rule, so this checks BY
# NAME, from the audit's own outputs rather than from either lane:
#
#   lanes    every field of the canonical snapshot is in exactly one of the
#            stored layout and Full's prepared layout
#   carried  every stored, non-scratch field the inventory marks UNDERIVED or
#            setup-writes.tsv lists, less the held list, is in the prepared
#            lane, not in the stored lane, and still mutable
#   fills    and conversely: no field kept at its fill in the stored lane is one
#            setup writes, unless it is held
#   held     core-initials-held.tsv is exactly the reference's shape refusals
#            together with the fields the audit has no count for
#   scratch  a scratch field is not in the snapshot, so not compared; that is
#            only right if the original holds no value for it before the first
#            tick. Each one's ivar is looked up on the objects the original
#            constructs (this configuration), and counted if it is defined.
#
# Each line is `name count faults...`; the caller pins every fault at zero.
ROOT = File.expand_path("../..", __dir__)
require "set"

ARGV.length == 10 or
  abort("usage: initial-sets.rb SNAPSHOT STORED PREPARED SCHEMA INVENTORY SETUP_WRITES HELD AUDIT_ERR SHAPEFIELDS WAD")
snapshot, stored, prepared, schema, inventory, setup_path, held_path, audit_err, shape_path, wad_path = ARGV

def rows(path) = File.readlines(path).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t", -1) }

snap = rows(snapshot).map(&:first).to_set
st = rows(stored).map(&:first).to_set
pr = rows(prepared).map(&:first).to_set
puts "lanes #{snap.length} both #{(st & pr).length} neither #{(snap - st - pr).length} " \
     "outside #{((st | pr) - snap).length}"

schema_rows = rows(schema)
name_of = schema_rows.to_h { |f| [f[5], f[0]] }
origin_of = schema_rows.to_h { |f| [f[0], f[5]] }
role_of = schema_rows.to_h { |f| [f[0], f[1]] }
held = rows(held_path).map(&:first).to_set
setup = rows(setup_path).reject { |f| f[0] == "field" }.map(&:first).to_set

inv = rows(inventory)
header = inv.shift
col = header.each_with_index.to_h
key = ->(f) { "#{f[col['class']]}@#{f[col['ivar']]}" }
# A FOLDED ivar has no schema row of its own -- what it held is carried by the
# fields its `fold:` names (tools/doom/core-representations.tsv) -- so it is not
# looked for in either lane; those fields are, under their own origins.
folds = File.readlines(File.join(ROOT, "tools/doom/core-representations.tsv"))
            .reject { |l| l.start_with?("#") || l.strip.empty? }
            .map { |l| l.chomp.split("\t", -1) }.select { |f| f[1].to_s.start_with?("fold:") }.map(&:first).to_set
stored_fields = inv.select { |f| f[col["disposition"]] == "stored" && f[col["role"]] != "scratch" }
                   .reject { |f| folds.include?(key[f]) }
underived = stored_fields.select { |f| f[col["initial"]] == "UNDERIVED" }.map { |f| key[f] }.to_set
setup_written = stored_fields.map { |f| key[f] }.select { |k| setup.include?(k) }.to_set
carried = ((underived | setup_written) - held).map { |k| name_of.fetch(k) }
puts "carried #{carried.length} underived #{(underived - held).length} " \
     "setup-only #{(setup_written - underived - held).length} " \
     "not-prepared #{carried.count { |n| !pr.include?(n) }} stored #{carried.count { |n| st.include?(n) }} " \
     "resource #{carried.count { |n| role_of[n] == 'resource' }}"
kept = st.reject { |n| held.include?(origin_of[n]) }
# A FIELD NO IVAR HOLDS (origin `added:`, tools/doom/core-added.tsv) is kept at
# its fill by construction: nothing in the original sets it. Counted apart.
puts "fills #{kept.length} setup-written #{kept.count { |n| setup.include?(origin_of[n]) }} " \
     "added #{kept.count { |n| origin_of[n].to_s.start_with?('added:') }}"

line = File.readlines(audit_err).grep(/no count at all: /).first.to_s
nocount = line.sub(/\A.*no count at all: /, "").split("; ").map { |s| s[/\A(\S+)/, 1] }.compact.to_set
shapes = File.readlines(shape_path).map(&:strip).reject(&:empty?).map { |n| origin_of.fetch(n) }.to_set
want = nocount | shapes
puts "held #{held.length} shape #{shapes.length} no-count #{nocount.length} mismatch #{(held ^ want).length}"

%w[wad level texnames texture sprites statusbar hud render info random game].each do |f|
  require_relative File.join(ROOT, "examples/doom/lib/doom", f)
end
wad = Doom::Wad.new(wad_path)
lv = Doom::Level.new(wad, "E1M1", 1)
tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
rnd = Doom::Random.new; rnd.clear
g = Doom::Game.new(wad, lv, 2, rnd, tx)
sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
sb = Doom::StatusBar.new(wad); sb.start(g.pl_weaponowned)
r = Doom::Renderer.new(lv, wad, wad.bytes_by_name("COLORMAP"), tx, sp, g, 10, false, 1)
hud = Doom::Hud.new(wad, r.screenwidth, r.screenheight, 1)
objects = { "Game" => g, "Level" => lv, "Random" => rnd, "Renderer" => r, "StatusBar" => sb,
            "Hud" => hud, "Textures" => tx, "Sprites" => sp, "Wad" => wad }
scratch = schema_rows.select { |f| f[1] == "scratch" }
defined = []
unreachable = []
added = []
scratch.each do |f|
  # the port's own stacks and capacity cells: no original object holds them
  (added << f[0]; next) if f[5].start_with?("added:")
  cls, ivar = f[5].split("@@", 2)
  obj = objects[cls] or (unreachable << f[0]; next)
  defined << f[0] if obj.instance_variable_defined?(:"@#{ivar}")
end
puts "scratch #{scratch.length} in-snapshot #{scratch.count { |f| snap.include?(f[0]) }} " \
     "defined-before-tick #{defined.length} unreachable #{unreachable.length} added #{added.length}" +
     (defined.empty? && unreachable.empty? ? "" : " #{(defined + unreachable).first(3).join(',')}")
