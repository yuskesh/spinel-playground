# frozen_string_literal: true
#
# tests/doom-core/source-registry.rb — the source entries' parameters against the resident layout.
#
#   ruby tests/doom-core/source-registry.rb FIELDS CONTRACTS_DIR GENERATED_DIR ACCESS
#
# FIELDS is tests/doom-core/fixtures/source/fields.tsv; CONTRACTS_DIR holds the
# `*.contract` files; GENERATED_DIR is tools/doom/state-schema.rb's output
# (buffers.tsv, slots.tsv, registry.h); ACCESS is examples/doom/core/access.tsv.
#
# A contract says what an entry's parameters are; the schema says what the
# game's resident fields are. Nothing ties the two unless something checks each
# parameter against the field it will be handed. For every row:
#
#   * every buffer parameter and every index parameter (`i_*`) of the entry is
#     listed exactly once in each context that calls it, and nothing else is;
#   * a buffer parameter names an allocation in buffers.tsv, described the same
#     way -- element and count -- by the generated registry.h, with the
#     contract's element; `state` names `core_state`, and only `state` may;
#   * an index parameter names a scalar slot in slots.tsv, at the index
#     registry.h gives it, and says whether the entry reads that cell (`in`) or
#     writes it (`inout`); a written cell needs a writable `state` and an
#     `inout` doom_core_render access row, and a writable `state` needs at
#     least one written cell;
#   * every named field has a doom_core_render access row, and a buffer the
#     contract writes must be `inout` there;
#   * two buffer parameters of one call are never the same field, and neither
#     are two index parameters -- one cell passed as two;
#   * `none`, `arg:NAME`, `job:NAME` and `derived:WHAT` are what they say:
#     `arg:` only for a buffer a draw context fills from an argument; `none` only for a
#     buffer, `job:` only in a queued context, `derived:` only for an i64 index
#     table.
#
# Prints `fields ROWS rows, CONTEXTS contexts, FIELDS fields (SLOTS slots): ok`
# or one `refused ...` line per violation, exiting 1.
fields_path, contracts_dir, gen_dir, access_path = ARGV
[fields_path, contracts_dir, gen_dir, access_path].all? or
  abort("usage: source-registry.rb FIELDS CONTRACTS_DIR GENERATED_DIR ACCESS")

errors = []
refuse = ->(msg) { errors << "refused #{msg}" }

# The contracts: each entry's buffer parameters (element, mode) and index parameters.
contracts = {}
Dir[File.join(contracts_dir, "*.contract")].sort.each do |path|
  entry = File.basename(path, ".contract")
  params = {}
  File.foreach(path) do |ln|
    f = ln.split
    next unless f[0] == "param"
    if f[2] == "buffer"
      params[f[1]] = { kind: :buffer, element: f[3], mode: f[4] }
    elsif f[2] == "scalar" && f[1].start_with?("i_")
      params[f[1]] = { kind: :index }
    end
  end
  contracts[entry] = params
end

buffers = {}
File.foreach(File.join(gen_dir, "buffers.tsv")) do |ln|
  next if ln.start_with?("#") || ln.strip.empty?
  name, role, element, count, = ln.chomp.split("\t", -1)
  buffers[name] = { role: role, element: element, count: Integer(count, 10) }
end
slots = {}
File.foreach(File.join(gen_dir, "slots.tsv")) do |ln|
  next if ln.start_with?("#") || ln.strip.empty?
  name, index, = ln.chomp.split("\t", -1)
  slots[name] = Integer(index, 10)
end
registry = File.read(File.join(gen_dir, "registry.h"))
reg_slots = registry.scan(/^#define SPINEL_DOOM_SLOT_([A-Z0-9_]+) (\d+)$/).to_h { |n, i| [n, Integer(i, 10)] }
reg_allocs = registry.scan(/^  \{ "([a-z0-9_]+)", "([a-z]+)", "([a-z0-9]+)", (\d+) \},$/)
                     .to_h { |n, r, e, c| [n, { role: r, element: e, count: Integer(c, 10) }] }
access = {}
File.foreach(access_path) do |ln|
  next if ln.start_with?("#") || ln.strip.empty?
  entry, field, mode = ln.chomp.split("\t", -1)
  access[field] = mode if entry == "doom_core_render"
end

groups = Hash.new { |h, k| h[k] = {} }
rows = 0
File.foreach(fields_path).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  f.length == 5 or (refuse.("#{fields_path}:#{i}: #{f.length} columns, want 5") && next)
  context, entry, param, field, use = f
  rows += 1
  c = contracts[entry] or (refuse.("#{fields_path}:#{i}: no contract #{entry}") && next)
  spec = c[param] or (refuse.("#{fields_path}:#{i}: #{entry} has no buffer or index parameter #{param}") && next)
  g = groups[[context, entry]]
  g.key?(param) and refuse.("#{fields_path}:#{i}: #{context} #{entry}.#{param} is listed twice")
  g[param] = [field, use]
  where = "#{context} #{entry}.#{param} -> #{field}"
  if field.start_with?("job:")
    context.start_with?("queued-") or refuse.("#{where}: a job record field outside a queued context")
    next
  end
  if spec[:kind] == :index
    %w[in inout].include?(use) or (refuse.("#{where}: an index parameter says `in` or `inout`, not #{use.inspect}") && next)
    slots.key?(field) or (refuse.("#{where}: #{field} is not a scalar slot") && next)
    reg_slots[field.upcase] == slots[field] or
      refuse.("#{where}: registry.h puts #{field} at #{reg_slots[field.upcase].inspect}, slots.tsv at #{slots[field]}")
    state = c["state"]
    if use == "inout"
      state && state[:mode] == "inout" or refuse.("#{where}: the entry writes this cell and its state is not inout")
    end
    mode = access[field] or (refuse.("#{where}: access.tsv gives doom_core_render no #{field}") && next)
    use == "inout" && mode != "inout" and refuse.("#{where}: the entry writes #{field} and doom_core_render has it as #{mode}")
    next
  end
  # a buffer parameter
  if field.start_with?("derived:")
    spec[:element] == "i64" or refuse.("#{where}: a derived index table is i64, the contract says #{spec[:element]}")
    %w[in inout].include?(use) or refuse.("#{where}: a derived index table says whether its cells are written")
    next
  end
  use == "-" or refuse.("#{where}: a buffer parameter has no `use`, got #{use.inspect}")
  next if field == "none"
  if field.start_with?("arg:")
    context.start_with?("draw-") or refuse.("#{where}: a call argument outside a draw context")
    next
  end
  (param == "state") == (field == "core_state") or
    refuse.("#{where}: `state` is core_state, and core_state is only ever `state`")
  b = buffers[field] or (refuse.("#{where}: #{field} is not an allocation") && next)
  b[:element] == spec[:element] or refuse.("#{where}: #{field} is #{b[:element]}, the contract says #{spec[:element]}")
  reg_allocs[field] == b or refuse.("#{where}: registry.h describes #{field} as #{reg_allocs[field].inspect}, buffers.tsv as #{b.inspect}")
  next if field == "core_state" # its cells are checked through the index rows
  mode = access[field] or (refuse.("#{where}: access.tsv gives doom_core_render no #{field}") && next)
  spec[:mode] == "inout" && mode != "inout" and
    refuse.("#{where}: the contract writes #{param} and doom_core_render has #{field} as #{mode}")
end

groups.each do |(context, entry), g|
  missing = contracts[entry].keys - g.keys
  missing.empty? or refuse.("#{context} #{entry}: #{missing.join(', ')} not listed")
  { "buffer" => ->(p) { contracts[entry][p] && contracts[entry][p][:kind] == :buffer },
    "index" => ->(p) { contracts[entry][p] && contracts[entry][p][:kind] == :index } }.each do |what, is|
    named = g.select { |p, _| is.(p) }.map { |_, (fl, _)| fl }.grep_v(/\A(none|arg:.*|job:.*|derived:.*)\z/)
    dup = named.tally.select { |_, n| n > 1 }.keys
    dup.empty? or refuse.("#{context} #{entry}: #{dup.join(', ')} passed as two #{what} parameters")
  end
  state = contracts[entry]["state"]
  if state && state[:mode] == "inout" && g["state"] && g["state"][0] == "core_state"
    g.any? { |p, (_, u)| u == "inout" && contracts[entry][p] } or
      refuse.("#{context} #{entry}: state is inout and no cell is written")
  end
end
# An entry with no buffer and no index parameter hands over no storage, so it
# has nothing for a row to name (dc_sp_absang, over one scalar).
contracts.each do |entry, params|
  next if params.empty?
  groups.keys.any? { |_, e| e == entry } or refuse.("#{entry} is called from no context")
end

if errors.empty?
  all = groups.values.flat_map { |g| g.values.map(&:first) }.grep_v(/\A(none|arg:.*|job:.*|derived:.*)\z/).uniq
  puts "fields #{rows} rows, #{groups.keys.map(&:first).uniq.length} contexts, " \
       "#{all.length} fields (#{all.count { |n| slots.key?(n) }} slots): ok"
else
  puts errors
  exit 1
end
