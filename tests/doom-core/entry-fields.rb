# frozen_string_literal: true
#
# tests/doom-core/entry-fields.rb — the three entries' parameters against the resident layout.
#
#   ruby tests/doom-core/entry-fields.rb ENTRIES_DIR GENERATED_DIR SCHEMA ACCESS JOBS_RB
#
# ENTRIES_DIR is examples/doom/core/entries (fields.tsv, the contracts, the slot
# tables); GENERATED_DIR is tools/doom/state-schema.rb's output over the
# committed schema; SCHEMA and ACCESS are examples/doom/core/state.tsv and
# access.tsv; JOBS_RB is the original examples/doom/lib/doom/jobs.rb, whose
# Jobs#reset the zero table must match.
#
# tools/doom/core-entries.rb writes the map and the contracts from the same
# manifests, so agreement with it is not the point. What this checks is the map
# against the LAYOUT Full allocates -- a separate generator -- and the entry
# against its manifest:
#
#   * every buffer parameter of each contract has one row, and every row a
#     parameter, with the contract's element and mode;
#   * a field is an allocation in buffers.tsv with that element; `core_state`
#     only for `state`; a `derived:` table names an existing slot table whose
#     every row is a slot in slots.tsv, each once;
#   * each mode is the entry's access.tsv row; no field is bound twice in one
#     entry;
#   * EVERY access row of the entry is taken: by a parameter, or by a slot
#     table's row -- or the field is one no shipped configuration writes
#     (`#unreached` in the schema) or a row of not-taken.tsv, whose kind
#     and reason say why -- and a not-taken row the entry does take is refused;
#   * a `derived:FIELD` row names a FIELD the entry takes, and the port's
#     source reads it: a slot field as `TABLE[CONSTANT]` with its slot
#     table's parameter and constant, a buffer field as `PARAM[` with the
#     parameter bound to it;
#   * the render entry's zero table is exactly the cells Jobs#reset sets to 0;
#   * units.tsv is sources.tsv less its `#excluded` units, each with a reason;
#   * each slot table row's constant is that position in the source, and its
#     field has an access row for the entry; Jobs#reset's non-zero writes are
#     each named with where the port makes them.
#
# Prints `entry-fields: ...: ok` lines, or one `refused ...` line per
# violation, exiting 1.
require "set"

dir, gen, schema_path, access_path, jobs_rb = ARGV
[dir, gen, schema_path, access_path, jobs_rb].all? or
  abort("usage: entry-fields.rb ENTRIES_DIR GENERATED_DIR SCHEMA ACCESS JOBS_RB")
errors = []
refuse = ->(m) { errors << "refused #{m}" }

rows = Hash.new { |h, k| h[k] = {} }
File.foreach(File.join(dir, "fields.tsv")) do |l|
  next if l.start_with?("#") || l.strip.empty?
  e, p, f, el, m = l.chomp.split("\t", -1)
  rows[e].key?(p) and refuse.("#{e} #{p}: listed twice")
  rows[e][p] = { field: f, element: el, mode: m }
end
buffers = {}
File.foreach(File.join(gen, "buffers.tsv")) do |l|
  next if l.start_with?("#") || l.strip.empty?
  n, _role, el, = l.chomp.split("\t", -1)
  buffers[n] = el
end
slots = {}
File.foreach(File.join(gen, "slots.tsv")) do |l|
  next if l.start_with?("#") || l.strip.empty?
  n, i, = l.chomp.split("\t", -1)
  slots[n] = Integer(i, 10)
end
access = Hash.new { |h, k| h[k] = {} }
File.foreach(access_path) do |l|
  next if l.start_with?("#") || l.strip.empty?
  e, f, m = l.chomp.split("\t", -1)
  access[e][f] = m
end
unreached = File.foreach(schema_path).select { |l| l.start_with?("#unreached\t") }.map { |l| l.split("\t")[1] }.to_set

# A slot table: [position, constant or nil, field] rows in order; a position
# out of order is refused by name.
TABLE_ERRORS = []
def table_rows(path)
  File.foreach(path).reject { |l| l.start_with?("#") || l.strip.empty? }.each_with_index.map do |l, i|
    f = l.chomp.split("\t")
    (f[0] =~ /\A\d+\z/ && Integer(f[0], 10) == i) or
      TABLE_ERRORS << "refused #{File.basename(path)}: row #{i} says position #{f[0].inspect}"
    [i, f.length == 3 ? f[1] : nil, f[-1]]
  end
end
def table(path) = table_rows(path).map(&:last)

# THE CONSTANTS THE PORT INDEXES WITH: `NAME = N` at the top level of the units,
# so a slot table's constant column can be held to the source.
CONSTANTS = {}
src_units = Dir[File.join(dir, "..", "src", "*.rb")]
src_units.empty? and abort("entry-fields: no units under #{File.join(dir, '..', 'src')}; the slot constants cannot be read")
src_units.each do |f|
  File.foreach(f) { |l| CONSTANTS[$1] = Integer($2, 10) if l =~ /\A([A-Z][A-Z0-9_]*) = (\d+)\s*\z/ }
end
# the units' code, comments left out, for a derived: row's read
SRC_CODE = src_units.sort.map { |f| File.readlines(f).reject { |l| l.lstrip.start_with?("#") }.join }.join

# The rows no parameter takes, each with its kind and reason (not-taken.tsv).
NOT_TAKEN = {}
File.foreach(File.join(dir, "not-taken.tsv")).with_index(1) do |l, i|
  next if l.start_with?("#") || l.strip.empty?
  f = l.chomp.split("\t", -1)
  f.length == 4 && f.none? { |c| c.strip.empty? } or (refuse.("not-taken.tsv:#{i}: want entry, field, kind, reason"); next)
  f[2] =~ /\A(same:[a-z0-9_]+|derived:[a-z0-9_]+|gate:\w+|dead-store:\w+|message|constants)\z/ or
    refuse.("not-taken.tsv:#{i}: kind #{f[2].inspect}")
  NOT_TAKEN[[f[0], f[1]]] = f[2]
end

rows.each do |entry, params|
  contract = File.join(dir, "#{entry}.contract")
  File.exist?(contract) or (refuse.("#{entry}: no contract"); next)
  cparams = {}
  File.foreach(contract) do |l|
    f = l.split
    cparams[f[1]] = { element: f[3], mode: f[4] } if f[0] == "param" && f[2] == "buffer"
  end
  (cparams.keys - params.keys).each { |p| refuse.("#{entry} #{p}: a contract buffer with no field") }
  (params.keys - cparams.keys).each { |p| refuse.("#{entry} #{p}: a field row for no contract buffer") }
  taken = Set.new
  bound = {}
  # how the entry takes each field: [param] for a buffer, [param, constant] for a slot
  reads = {}
  params.each do |p, r|
    c = cparams[p] or next
    (c[:element] == r[:element] && c[:mode] == r[:mode]) or
      refuse.("#{entry} #{p}: the contract says #{c[:element]} #{c[:mode]}, the map #{r[:element]} #{r[:mode]}")
    f = r[:field]
    if f.start_with?("derived:")
      path = File.join(dir, f.delete_prefix("derived:"))
      File.exist?(path) or (refuse.("#{entry} #{p}: no table #{path}"); next)
      (r[:element] == "i64" && r[:mode] == "in") or refuse.("#{entry} #{p}: an index table is i64 in")
      trows = table_rows(path)
      fs = trows.map(&:last)
      trows.each do |pos, const, sf|
        slots.key?(sf) or refuse.("#{entry} #{p}: #{sf} is not a slot of the layout")
        # a slot the entry indexes is a cell of core_state the manifest gives it
        access[entry].key?(sf) or refuse.("#{entry} #{p}: #{sf} is a slot of its table and access.tsv gives #{entry} no row for it")
        if const
          CONSTANTS.key?(const) or refuse.("#{entry} #{p}: #{const} is defined in no unit")
          CONSTANTS.key?(const) && CONSTANTS[const] != pos and
            refuse.("#{entry} #{p}: #{const} is #{CONSTANTS[const]} in the source and row #{pos} of its table")
        end
        taken << sf
        reads[sf] = [p, const]
      end
      fs.uniq.length == fs.length or refuse.("#{entry} #{p}: a slot is named twice")
      next
    end
    if f == "core_state"
      p == "state" or refuse.("#{entry} #{p}: only `state` is core_state")
    else
      p == "state" and refuse.("#{entry} state: is #{f}, not core_state")
      buffers.key?(f) or (refuse.("#{entry} #{p}: #{f} is not an allocation of the layout"); next)
      buffers[f] == r[:element] or refuse.("#{entry} #{p}: #{f} is #{buffers[f]}, the map says #{r[:element]}")
      m = access[entry][f]
      m or refuse.("#{entry} #{p}: access.tsv gives #{entry} no row for #{f}")
      m && m != r[:mode] and refuse.("#{entry} #{p}: #{f} is #{m} in access.tsv, the map says #{r[:mode]}")
    end
    bound[f] and refuse.("#{entry}: #{f} is bound to both #{bound[f]} and #{p}")
    bound[f] = p
    taken << f
    reads[f] = [p]
  end
  NOT_TAKEN.each do |(e, f), kind|
    next unless e == entry
    taken.include?(f) and refuse.("#{entry}: not-taken.tsv lists #{f}, which the entry takes")
    access[entry].key?(f) or refuse.("#{entry}: not-taken.tsv lists #{f}, which access.tsv does not give it")
    if kind.start_with?("same:")
      taken.include?(kind.delete_prefix("same:")) or
        refuse.("#{entry}: #{f} is the same as #{kind.delete_prefix('same:')}, which the entry does not take")
    end
    # DERIVED: the port does not keep f and looks the same value up through the
    # field it names, so that field must reach the entry and the port must read it.
    if kind.start_with?("derived:")
      g = kind.delete_prefix("derived:")
      if !taken.include?(g)
        refuse.("#{entry}: #{f} is derived from #{g}, which the entry does not take")
      else
        p, const = reads[g]
        read = if reads[g].length == 2
                 const && SRC_CODE.match?(/\b#{Regexp.escape(p)}\[#{Regexp.escape(const)}\]/)
               else
                 SRC_CODE.match?(/\b#{Regexp.escape(p)}\[/)
               end
        read or refuse.("#{entry}: #{f} is derived from #{g}, which the port's source never reads " \
                        "(#{reads[g].length == 2 ? "#{p}[#{const || '?'}]" : "#{p}["})")
      end
    end
  end
  untaken = access[entry].keys.reject { |f| taken.include?(f) || unreached.include?(f) || NOT_TAKEN.key?([entry, f]) }
  untaken.sort.each { |f| refuse.("#{entry}: access.tsv's #{f} is taken by no parameter and no slot") }
  if errors.empty?
    puts "entry-fields: #{entry}: #{params.size} buffer(s), #{taken.size} field(s) taken, " \
         "#{access[entry].size} access row(s) covered: ok"
  end
end

# The zero table against the original's Jobs#reset.
body = File.read(jobs_rb)[/^    def reset\n(.*?)^    end\n/m, 1] or abort("entry-fields: no Jobs#reset in #{jobs_rb}")
zeroed = body.scan(/^\s*@(\w+) = 0$/).flatten.map { |n| "jobs_#{n}" }
# EVERY OTHER WRITE IN Jobs#reset is named here with where the port makes it;
# a new one is refused until it is.
OTHER_RESETS = { "fuzz_suffix = 1" => "dc_rv_jobs_reset's i_fuzz_suffix (R_FUZZ_SUFFIX)" }.freeze
others = body.scan(/^\s*@(\w+ = .+)$/).flatten.reject { |w| w.end_with?(" = 0") }
(others - OTHER_RESETS.keys).each { |w| refuse.("Jobs#reset writes @#{w}, which the zero table does not hold and nothing here places") }
zt = table(File.join(dir, "render-zero.tsv"))
zt == zeroed or refuse.("render-zero.tsv is not Jobs#reset's zeroes: missing #{(zeroed - zt).join(', ')}; " \
                        "extra #{(zt - zeroed).join(', ')}#{zt.sort == zeroed.sort ? '; order differs' : ''}")
puts "entry-fields: render-zero.tsv: #{zt.length} cell(s), Jobs#reset's zeroes: ok" if errors.empty?

# The entries' units against sources.tsv: every unit accounted for.
rows = ->(path) { File.readlines(path).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t") } }
sources = rows.(File.join(dir, "..", "sources.tsv"))
units_path = File.join(dir, "units.tsv")
units = rows.(units_path)
excl_rows = File.readlines(units_path).select { |l| l.start_with?("#excluded\t") }.map { |l| l.chomp.split("\t", -1) }
excl_rows.each { |f| (f.length == 3 && !f[2].strip.empty?) or refuse.("units.tsv excludes #{f[1]} without a reason") }
excluded = excl_rows.map { |f| f[1] }
excluded.uniq.length == excluded.length or refuse.("units.tsv excludes a unit twice")
(excluded & units.map(&:first)).each { |u| refuse.("units.tsv both packs and excludes #{u}") }
(excluded - sources.map(&:first)).each { |u| refuse.("units.tsv excludes #{u}, which sources.tsv does not list") }
want = sources.reject { |f, _| excluded.include?(f) }
want == units or
  refuse.("units.tsv is not sources.tsv less its #excluded units: " \
          "unaccounted #{(want.map(&:first) - units.map(&:first)).join(', ')}; " \
          "unknown #{(units.map(&:first) - want.map(&:first)).join(', ')}" \
          "#{want.map(&:first) == units.map(&:first) ? '; a digest or the order differs' : ''}")
puts "entry-fields: units.tsv: #{units.length} unit(s) packed, #{excluded.length} excluded with a reason: ok" if errors.empty?

errors.concat(TABLE_ERRORS.uniq)
errors.each { |e| puts e }
exit(errors.empty? ? 0 : 1)
