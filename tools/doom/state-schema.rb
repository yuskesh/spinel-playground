# frozen_string_literal: true
#
# tools/doom/state-schema.rb — decision 0008 task 5's state schema generator.
#
#   ruby tools/doom/state-schema.rb --schema FILE --access FILE --output DIR
#                                   [--catalog FILE]
#
# The schema enumerates every field CORE's resident storage holds. This reads
# it, refuses everything it cannot vouch for, and writes three things:
#
#   slots.rb        the generated constants for scalar fields that share a
#                   named i64 state buffer -- a data layout, not a new Ruby
#                   object and not a pointer type
#   buffers.tsv     one row per allocation, with its element type, count and
#                   initial fill, for Full to allocate and release once
#   snapshot.tsv    the canonical snapshot layout: schema-ordered, fixed-width
#                   little-endian, with field name, type and count. It carries
#                   no C padding, no addresses and no undefined scratch bytes,
#                   because a comparison that included any of those would be
#                   comparing the allocator rather than the game.
#
# THE GRAMMAR IS 0008's AND IS NOT EXTENDED HERE. Seven columns -- name, role,
# element, count, initial, origin, writers. `count` is `fixed:N`, `level:NAME`,
# `screen:NAME`, `limit:NAME` or `table:NAME`, and NAME must resolve in the
# prepared catalog: there is no evaluation of Ruby expressions from a manifest,
# because a manifest that could compute could compute something nobody
# reviewed. `initial` is an integer fill or `prepared:NAME`.
#
# NO ROW MAY BE ABSENT AND NO ROW MAY BE INVENTED. A field the audit found and
# the schema does not list is a field that would disappear from the migration
# through an unlisted accessor, so `--inventory` compares the two by name.

require "optparse"
require "digest"
require "fileutils"
require "set"

PROG = "state-schema"

opt = {}
OptionParser.new do |o|
  o.on("--schema FILE") { |v| opt[:schema] = v }
  o.on("--access FILE") { |v| opt[:access] = v }
  o.on("--output DIR") { |v| opt[:output] = v }
  o.on("--catalog FILE") { |v| opt[:catalog] = v }
  o.on("--inventory FILE") { |v| opt[:inventory] = v }
end.parse!

CATEGORIES = %w[
  usage schema access catalog duplicate-field unknown-count unbound-count
  count-overflow bad-initial prepared-length bad-element bad-role overlap
  unknown-buffer inventory
].freeze

def refuse(category, message, origin = nil)
  CATEGORIES.include?(category) or raise "unknown refusal category #{category.inspect}"
  warn("#{PROG}: #{category}: #{origin ? "#{origin}: " : ''}#{message}")
  exit(1)
end

%i[schema access output].each { |k| opt[k] or refuse("usage", "--#{k} is required") }
File.exist?(opt[:schema]) or refuse("usage", "no schema at #{opt[:schema]}")
File.exist?(opt[:access]) or refuse("usage", "no access manifest at #{opt[:access]}")

ROLES = %w[resource persistent scratch output].freeze
ELEMENTS = { "u8" => 1, "i8" => 1, "u16" => 2, "i16" => 2, "i32" => 4, "u32" => 4, "i64" => 8 }.freeze
COUNT_KINDS = %w[fixed level screen limit table].freeze

# --- the prepared catalog ------------------------------------------------------
# What a `level:`, `screen:`, `limit:` or `table:` count may name, and what a
# `prepared:` initial may name, with the length Full will hand over. Supplied
# rather than inferred: these are facts about the resources Full prepares, and
# the generator's job is to check the schema against them, not to guess them.
catalog = {}
prepared = {}
if opt[:catalog]
  File.exist?(opt[:catalog]) or refuse("usage", "no catalog at #{opt[:catalog]}")
  File.foreach(opt[:catalog]).with_index(1) do |ln, i|
    next if ln.start_with?("#") || ln.strip.empty?
    f = ln.chomp.split("\t", -1)
    origin = "#{opt[:catalog]}:#{i}"
    f.length == 3 or refuse("catalog", "#{f.length} column(s), want 3 (kind, name, value)", origin)
    kind, name, value = f
    case kind
    when "count"
      Integer(value, 10) >= 0 or refuse("catalog", "a count may not be negative", origin)
      catalog[name] = Integer(value, 10)
    when "prepared"
      prepared[name] = Integer(value, 10)
    else
      refuse("catalog", "kind #{kind.inspect} is not `count` or `prepared`", origin)
    end
  end
end

# --- the schema ----------------------------------------------------------------
U64_MAX = 18_446_744_073_709_551_615

fields = []
seen = {}
File.foreach(opt[:schema]).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  origin = "#{opt[:schema]}:#{i}"
  f.length == 7 or
    refuse("schema", "#{f.length} column(s), want 7 (name, role, element, count, initial, origin, writers)", origin)
  name, role, element, count, initial, source, writers = f
  name =~ /\A[a-z][a-z0-9_]*\z/ or
    refuse("schema", "#{name.inspect} is not a field name (lower snake case)", origin)
  seen[name] and
    refuse("duplicate-field", "#{name} is listed twice, at line #{seen[name]} and here", origin)
  seen[name] = i
  ROLES.include?(role) or refuse("bad-role", "role #{role.inspect} is not one of #{ROLES.join(', ')}", origin)
  ELEMENTS.key?(element) or
    refuse("bad-element", "element #{element.inspect} is not one of #{ELEMENTS.keys.join(', ')}", origin)
  source.strip.empty? and refuse("schema", "#{name} names no origin", origin)
  writers.strip.empty? and refuse("schema", "#{name} names no writer", origin)

  kind, _, cname = count.partition(":")
  COUNT_KINDS.include?(kind) or
    refuse("unknown-count", "count #{count.inspect} is not #{COUNT_KINDS.map { |k| k + ':NAME' }.join(', ')}", origin)
  n =
    if kind == "fixed"
      cname =~ /\A[0-9]+\z/ or refuse("unknown-count", "fixed:#{cname} is not a number", origin)
      Integer(cname, 10)
    else
      catalog.key?(cname) or
        refuse("unbound-count", "#{count} names nothing in the prepared catalog", origin)
      catalog[cname]
    end
  n >= 0 or refuse("unknown-count", "a count may not be negative", origin)
  # The BYTE SIZE is what Full allocates, and a count that fits u64 can still
  # have a product that does not. Checked here as well as in Full: a schema
  # that cannot be allocated is a schema, not an allocation failure.
  bytes = n * ELEMENTS[element]
  bytes <= U64_MAX or
    refuse("count-overflow", "#{name} is #{n} x #{ELEMENTS[element]} bytes, which leaves u64", origin)

  fill = nil
  prep = nil
  if initial.start_with?("prepared:")
    prep = initial.sub("prepared:", "")
    if prepared.key?(prep)
      prepared[prep] == n or
        refuse("prepared-length", "#{prep} is #{prepared[prep]} element(s) and #{name} declares #{n}", origin)
    elsif catalog.key?(prep)
      # The initial names a catalog COUNT. That is allowed exactly when it is
      # THIS field's own count: the length and the count are then one number
      # stated once, and they cannot drift. Naming a different catalog entry
      # is refused -- that would be a length nobody checked against anything.
      prep == cname or
        refuse("prepared-length",
               "#{name} counts #{count} and opens prepared:#{prep}; a prepared length " \
               "taken from the catalog must be this field's own count", origin)
    else
      refuse("bad-initial", "#{initial} names nothing the catalog prepares", origin)
    end
  else
    initial =~ /\A-?[0-9]+\z/ or
      refuse("bad-initial", "initial #{initial.inspect} is neither an integer nor prepared:NAME", origin)
    fill = Integer(initial, 10)
    lo, hi =
      case element
      when "u8" then [0, 255]
      when "i8" then [-128, 127]
      when "u16" then [0, 65_535]
      when "i16" then [-32_768, 32_767]
      when "i32" then [-2_147_483_648, 2_147_483_647]
      when "u32" then [0, 4_294_967_295]
      else [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807]
      end
    (fill >= lo && fill <= hi) or
      refuse("bad-initial", "#{fill} is outside #{element}", origin)
  end
  # `resource` is read-only to CORE, so an initial fill would be a value CORE
  # can never have written and Full never prepared.
  if role == "resource" && prep.nil?
    refuse("bad-initial", "#{name} is a resource; CORE only reads it, so it must be prepared:NAME", origin)
  end
  fields << { "name" => name, "role" => role, "element" => element,
              "count" => n, "count_spec" => count, "fill" => fill,
              "prepared" => prep, "origin" => source, "writers" => writers,
              "line" => i }
end
fields.empty? and refuse("schema", "the schema lists no fields")

# --- the access manifest -------------------------------------------------------
ENTRIES = %w[doom_core_input doom_core_step doom_core_render].freeze
access = []
pairs = {}
File.foreach(opt[:access]).with_index(1) do |ln, i|
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  origin = "#{opt[:access]}:#{i}"
  f.length == 3 or refuse("access", "#{f.length} column(s), want 3 (entry, buffer, mode)", origin)
  entry, buffer, mode = f
  ENTRIES.include?(entry) or
    refuse("access", "entry #{entry.inspect} is not one of #{ENTRIES.join(', ')}", origin)
  %w[in inout].include?(mode) or refuse("access", "mode #{mode.inspect} is not `in` or `inout`", origin)
  seen.key?(buffer) or
    refuse("unknown-buffer", "#{buffer} is not a field in the schema", origin)
  key = [entry, buffer]
  pairs[key] and
    refuse("access", "#{entry} lists #{buffer} twice, at line #{pairs[key]} and here", origin)
  pairs[key] = i
  access << { "entry" => entry, "buffer" => buffer, "mode" => mode, "line" => i }
end

by_name = fields.to_h { |f| [f["name"], f] }
access.each do |a|
  f = by_name[a["buffer"]]
  origin = "#{opt[:access]}:#{a['line']}"
  # A resource is prepared before play and CORE only reads it. Declaring one
  # `inout` would be the manifest granting a permission the role denies, and
  # the two would then disagree about the same buffer.
  if f["role"] == "resource" && a["mode"] == "inout"
    refuse("overlap", "#{a['buffer']} is a resource and #{a['entry']} asks for inout; " \
                      "CORE only reads a resource", origin)
  end
  # An output is written and not read back, so an entry that declares it `in`
  # has declared the wrong direction rather than a narrower one.
  if f["role"] == "output" && a["mode"] == "in"
    refuse("overlap", "#{a['buffer']} is an output and #{a['entry']} asks for in; " \
                      "an output is written, not read", origin)
  end
end

# --- every field the audit found is here ---------------------------------------
if opt[:inventory]
  File.exist?(opt[:inventory]) or refuse("usage", "no inventory at #{opt[:inventory]}")
  want = Set.new
  File.foreach(opt[:inventory]).with_index(1) do |ln, i|
    next if ln.start_with?("#") || ln.strip.empty?
    f = ln.chomp.split("\t", -1)
    next if i == 1 && f[0] == "class"   # the header row
    next if f.length < 2
    want << "#{f[0]}@#{f[1]}"
  end
  have = fields.map { |f| f["origin"] }.to_set
  missing = (want - have).to_a.sort
  unless missing.empty?
    refuse("inventory",
           "#{missing.length} field(s) the audit found have no schema row: " +
           missing.first(5).join(", ") +
           (missing.length > 5 ? " (and #{missing.length - 5} more)" : ""))
  end
end

# --- what is generated ----------------------------------------------------------
FileUtils.mkdir_p(opt[:output])

def publish(dest, text)
  tmp = File.join(File.dirname(dest), ".#{File.basename(dest)}.#{Process.pid}.tmp")
  File.binwrite(tmp, text)
  File.rename(tmp, dest)
end

# Scalar fields -- count 1 -- share one named i64 state buffer with generated
# constant indices. Each ARRAY keeps its own buffer: 0007 disallows overlap
# involving an `inout` range, and sharing one allocation between two arrays
# would be exactly that.
scalars = fields.select { |f| f["count"] == 1 && f["element"] == "i64" && f["role"] != "resource" }
arrays = fields - scalars
# THE SHARED BUFFER IS PREPARED BY FULL, ONE SLOT AT A TIME. Each scalar keeps
# its own initial -- a fill or `prepared:NAME` -- in `slots.tsv`, and
# `buffers.tsv` names the whole buffer `prepared:core_state`: Full assembles it
# once from those rows (Doom::Core::Resources.core_state) and the session
# receives it like any other prepared buffer. It used to be one row with fill
# 0 and no per-slot initial, so a slot declaring -1 or `prepared:NAME`
# generated without complaint and opened at 0.
#
# `core_state` is this generator's name, so the schema may not use it.
unless scalars.empty?
  if (clash = fields.find { |f| f["name"] == "core_state" || f["prepared"] == "core_state" })
    refuse("duplicate-field",
           "#{clash['name']} uses the name core_state, which is the shared scalar buffer",
           "#{opt[:schema]}:#{clash['line']}")
  end
end

slots = +"# Generated by tools/doom/state-schema.rb -- do not edit.\n#\n"
slots << "# The scalar fields share one i64 buffer, `core_state`. These are indices\n"
slots << "# into it, not addresses: a data layout, not a new object or pointer type.\n\n"
slots << "module Doom\n  module CoreSlots\n"
scalars.each_with_index { |f, i| slots << "    #{f['name'].upcase} = #{i}\n" }
slots << "    COUNT = #{scalars.length}\n"
slots << "  end\nend\n"
publish(File.join(opt[:output], "slots.rb"), slots)

# The same table, machine readable. `slots.rb` is for generated Ruby to
# `require`; this is for anything that has to READ the layout -- the session
# wrapper builds a snapshot from it -- without evaluating Ruby to learn it.
slots_tsv = +"# Generated by tools/doom/state-schema.rb -- do not edit.\n"
slots_tsv << "# Each scalar field's index in the shared `core_state` i64 buffer, the\n"
slots_tsv << "# initial Full puts there (a fill or prepared:NAME), and where it came from.\n"
slots_tsv << "#field\tindex\tinitial\torigin\n"
scalars.each_with_index do |f, i|
  initial = f["prepared"] ? "prepared:#{f['prepared']}" : f["fill"].to_s
  slots_tsv << [f["name"], i, initial, f["origin"]].join("\t") << "\n"
end
publish(File.join(opt[:output], "slots.tsv"), slots_tsv)

buffers = +"# Generated by tools/doom/state-schema.rb -- do not edit.\n"
buffers << "# One row per allocation. Full allocates each once and releases each once.\n"
buffers << "#name\trole\telement\tcount\tinitial\n"
buffers << "core_state\tpersistent\ti64\t#{scalars.length}\tprepared:core_state\n" unless scalars.empty?
arrays.each do |f|
  buffers << [f["name"], f["role"], f["element"], f["count"],
              f["prepared"] ? "prepared:#{f['prepared']}" : f["fill"]].join("\t") << "\n"
end
publish(File.join(opt[:output], "buffers.tsv"), buffers)

# THE NATIVE REGISTRY. `slots.rb` is for generated Ruby; this is the same
# layout for the side that has no Ruby at all.
#
# A CORE entry is handed BUFFERS AND SCALARS, and the caller has to know which
# buffer and which index. Hard-coding either in a C driver makes the driver a
# second copy of the schema -- the layout would move here and not there, and
# nothing would say so. So the indices and the allocation table are GENERATED,
# from the same rows that generate everything else, and a caller that includes
# this header cannot disagree with the schema without failing to compile.
#
# This is decision 0008 task 5's "contract/binding data", and it is what
# connects the real 700-field schema to native execution: without it the only
# native lanes are fixtures with their own invented layouts.
reg = +"/* Generated by tools/doom/state-schema.rb -- do not edit. */\n"
reg << "#ifndef SPINEL_DOOM_STATE_REGISTRY_H\n"
reg << "#define SPINEL_DOOM_STATE_REGISTRY_H\n\n"
reg << "#include <stddef.h>\n#include <stdint.h>\n\n"
reg << "/* Every scalar field's index in the shared `core_state` i64 buffer. */\n"
scalars.each_with_index { |f, i| reg << "#define SPINEL_DOOM_SLOT_#{f['name'].upcase} #{i}\n" }
reg << "#define SPINEL_DOOM_SLOT_COUNT #{scalars.length}\n\n"
reg << "/* One id per allocation, in the order buffers.tsv lists them. */\n"
reg << "enum spinel_doom_buffer {\n"
alloc_names = (scalars.empty? ? [] : ["core_state"]) + arrays.map { |f| f["name"] }
alloc_names.each_with_index { |n, i| reg << "  SPINEL_DOOM_BUF_#{n.upcase} = #{i},\n" }
reg << "  SPINEL_DOOM_BUF_COUNT = #{alloc_names.length}\n};\n\n"
reg << "struct spinel_doom_alloc {\n"
reg << "  const char *name;\n  const char *role;\n  const char *element;\n"
reg << "  int64_t count;\n};\n\n"
reg << "/* The allocation table. A session fills one pointer per id; this says\n"
reg << "   what each id IS, so a mismatch is a compile error or a loud one. */\n"
reg << "static const struct spinel_doom_alloc spinel_doom_allocs[] = {\n"
reg << "  { \"core_state\", \"persistent\", \"i64\", #{scalars.length} },\n" unless scalars.empty?
arrays.each do |f|
  reg << "  { \"#{f['name']}\", \"#{f['role']}\", \"#{f['element']}\", #{f['count']} },\n"
end
reg << "};\n\n#endif\n"
publish(File.join(opt[:output], "registry.h"), reg)

# The canonical snapshot: schema order, fixed width, little endian. No padding,
# no addresses, no undefined scratch bytes.
snap = +"# Generated by tools/doom/state-schema.rb -- do not edit.\n"
snap << "# The canonical snapshot layout: schema-ordered, fixed-width little-endian.\n"
snap << "# `offset` is the byte at which the field's data begins. Scratch is excluded:\n"
snap << "# its bytes are undefined between calls and comparing them would compare the\n"
snap << "# allocator rather than the game.\n"
snap << "#field\telement\tcount\tbytes\toffset\n"
offset = 0
fields.reject { |f| f["role"] == "scratch" }.each do |f|
  bytes = f["count"] * ELEMENTS[f["element"]]
  snap << [f["name"], f["element"], f["count"], bytes, offset].join("\t") << "\n"
  offset += bytes
end
snap << "#total\t-\t-\t#{offset}\t-\n"
publish(File.join(opt[:output], "snapshot.tsv"), snap)

warn("#{PROG}: #{fields.length} field(s), #{scalars.length} scalar slot(s), " \
     "#{arrays.length} array buffer(s), #{access.length} access row(s), " \
     "snapshot #{offset} byte(s)")
