# frozen_string_literal: true
#
# tools/doom/core-native-prep.rb — Full's preparation, generated for the playable program.
#
#   ruby tools/doom/core-native-prep.rb --wad WAD [--out FILE]
#
# Writes examples/doom/core/full/nativeprep.rb (or FILE): Doom::Core::NativePrep,
# which the program the pinned Spinel compiles uses to open a session
# (native_session.rb) and to call the three entries.
#
# WHY GENERATED. Doom::Core::Resources.prepared reads each prepared field from
# the objects Full builds, by the origin core-acquired.tsv and
# core-representations.tsv give it -- by names computed at run time, which the
# pin refuses (probe of 2026-09-18: `instance_variable_get("@" + name)`
# compiles and fails with NoMethodError). A literal read of each field does
# compile. So the same origins are turned into literal code here, one method
# per field.
#
# ONE METHOD PER FIELD, AND NO SHARED STORE HELPER THAT TAKES THE VALUE. On
# this pin one value the compiler cannot type widens the parameter of any
# method it is passed to, and every other caller of that method then fails
# (docs/doom.md, "Known compiler defects on this pin"). Each method below reads
# its value into its own local and stores integers only.
#
# THE VALUE'S SHAPE is read, at generation time, from the objects CRuby builds
# for E1M1 with --wad: an Integer, true/false, an Array of either, a String of
# bytes or an Array of Strings. The shape is a property of the library's code,
# not of the map; the generated method refuses at run time a length that is
# not the session's count.
#
# THE FIELDS' OWN REPRESENTATION IS NOT CHANGED HERE. What is generated stores
# exactly the bytes Resources.prepared produces (flags as 0 and 1, strings
# joined), and the native lane compares the two snapshots cell by cell.
#
# THE i32-bits FIELDS (examples/doom/core/widths-repr.tsv, decision 0022
# section 2.4) hold a word Full keeps as 0..2**32-1 as its signed i32 pattern:
# their methods refuse a value outside that range and store v - 2**32 for
# one at 2**31 or past, as Resources.prepared and Reference do on their own.
#
# ONE FIELD IS READ DIFFERENTLY: level_reject. The pin cannot call `bytesize`
# on that value (docs/doom.md), so its length is the session's count -- the
# catalog's `rejectbytes`, which native_catalog.rb measures from the WAD
# directory -- and its bytes are read with `getbyte`, as lib/doom/sight.rb
# reads them.
require "optparse"
ROOT = File.expand_path("../..", __dir__)
opt = { out: File.join(ROOT, "examples/doom/core/full/nativeprep.rb") }
OptionParser.new do |o|
  o.on("--wad FILE") { |v| opt[:wad] = v }
  o.on("--out FILE") { |v| opt[:out] = v }
end.parse!
opt[:wad] or abort("usage: core-native-prep.rb --wad WAD [--out FILE]")
CORE = File.join(ROOT, "examples/doom/core")
%w[wad texnames texture level random info sprites game render statusbar hud jobs executor input record demo
   bytes specials tables].each { |f| require File.join(ROOT, "examples/doom/lib/doom", f) }
require File.join(CORE, "full/resources")

def rows(path)
  File.readlines(path).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t", -1) }
end

# --- the objects, as the program builds them (E1M1, skill 2) -----------------
wad = Doom::Wad.new(opt[:wad])
tx = Doom::Textures.new(wad, Doom::TextureNames.new(wad))
lv = Doom::Level.new(wad, "E1M1", 1)
rnd = Doom::Random.new
rnd.clear
g = Doom::Game.new(wad, lv, 2, rnd, tx)
sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
r = Doom::Renderer.new(lv, wad, wad.bytes_by_name("COLORMAP"), tx, sp, g, 10, false, 1)
r.job_mode = 1
sb = Doom::StatusBar.new(wad)
sb.start(g.pl_weaponowned)
require "tmpdir"
script = File.join(Dir.mktmpdir("native-prep"), "s.txt")
File.write(script, "0 10 forward\n")
OBJ = { "Wad" => wad, "Textures" => tx, "Level" => lv, "Random" => rnd, "Game" => g, "Sprites" => sp,
        "Renderer" => r, "StatusBar" => sb, "Hud" => Doom::Hud.new(wad, 320, 200, 1),
        "KeyScript" => Doom::KeyScript.new(script), "KeyState" => Doom::KeyState.new,
        "TiccmdBuilder" => Doom::TiccmdBuilder.new, "DemoWriter" => Doom::DemoWriter.new(2, 1, 1, 40_000),
        "Jobs" => r.instance_variable_get(:@jobs), "JobExecutor" => r.instance_variable_get(:@exec) }.freeze
# The parameter each class is handed to prepare() under.
VAR = { "Wad" => "wad", "Textures" => "tx", "Level" => "lv", "Random" => "rnd", "Game" => "g",
        "Sprites" => "sp", "Renderer" => "r", "StatusBar" => "sb", "Hud" => "hud", "KeyScript" => "ks",
        "KeyState" => "kst", "TiccmdBuilder" => "tc", "DemoWriter" => "dw", "Jobs" => "jobs",
        "JobExecutor" => "ex" }.freeze

def shape(v)
  case v
  when String then :bytes
  when Integer then :int
  when true, false then :bool
  when Array
    if v.all? { |x| x.is_a?(Integer) } then :ints
    elsif v.all? { |x| x == true || x == false } then :bools
    elsif v.all? { |x| x.is_a?(String) } then :strings
    else abort("core-native-prep: an array of #{v.map(&:class).uniq.join(', ')} has no shape")
    end
  else abort("core-native-prep: a #{v.class} has no shape")
  end
end

ELEM = { "u8" => 1, "i32" => 2, "u32" => 3, "i64" => 4, "i8" => 5, "u16" => 6, "i16" => 7 }.freeze
acquired = rows(File.join(ROOT, "tools/doom/core-acquired.tsv")).to_h { |f| [f[0], f[2]] }
producer = rows(File.join(ROOT, "tools/doom/core-representations.tsv"))
           .select { |f| f.length == 6 && !f[5].to_s.empty? }.to_h { |f| [f[1], f[5]] }
schema = rows(File.join(CORE, "state.tsv"))
i32_bits = rows(File.join(CORE, "widths-repr.tsv")).select { |f| f[1] == "i32-bits" }.map(&:first)

# --- one method per prepared field -------------------------------------------
methods = []
calls = []
body_for_value = lambda do |name, sh, read|
  case sh
  when :int
    "    v = #{read}\n    s.put(\"#{name}\", 0, v)\n"
  when :bool
    "    v = #{read}\n    s.put(\"#{name}\", 0, v ? 1 : 0)\n"
  when :ints, :bools
    cell = sh == :ints ? "a[i]" : "(a[i] ? 1 : 0)"
    if sh == :ints && i32_bits.include?(name)
      next "    a = #{read}\n    n = s.count(\"#{name}\")\n" \
        "    a.length == n or raise NativeSessionError, \"#{name}: \#{a.length} element(s), the session counts \#{n}\"\n" \
        "    i = 0\n    while i < n\n      v = a[i]\n" \
        "      v >= 0 && v <= 4294967295 or raise NativeSessionError, \"#{name}[\#{i}] = \#{v} is not a 32-bit word\"\n" \
        "      v -= 4294967296 if v >= 2147483648\n      s.put(\"#{name}\", i, v)\n      i += 1\n    end\n"
    end
    "    a = #{read}\n    n = s.count(\"#{name}\")\n" \
      "    a.length == n or raise NativeSessionError, \"#{name}: \#{a.length} element(s), the session counts \#{n}\"\n" \
      "    i = 0\n    while i < n\n      s.put(\"#{name}\", i, #{cell})\n      i += 1\n    end\n"
  when :bytes
    "    b = #{read}\n    n = s.count(\"#{name}\")\n" \
      "    b.bytesize == n or raise NativeSessionError, \"#{name}: \#{b.bytesize} byte(s), the session counts \#{n}\"\n" \
      "    i = 0\n    while i < n\n      c = b.getbyte(i)\n      s.put(\"#{name}\", i, c) if c != 0\n      i += 1\n    end\n"
  when :strings
    "    parts = #{read}\n    n = s.count(\"#{name}\")\n    at = 0\n    parts.each do |t|\n" \
      "      k = 0\n      while k < t.bytesize\n        at < n or raise NativeSessionError, \"#{name}: more bytes than the session counts (\#{n})\"\n" \
      "        c = t.getbyte(k)\n        s.put(\"#{name}\", at, c) if c != 0\n        at += 1\n        k += 1\n      end\n    end\n" \
      "    at == n or raise NativeSessionError, \"#{name}: \#{at} byte(s), the session counts \#{n}\"\n"
  end
end

schema.each do |name, _role, element, _count, initial, source|
  next unless initial.start_with?("prepared:")
  org = producer[name] || acquired[source] || source
  code, params =
    if name == "level_reject"
      # See the header: the length is the session's count, and no bytesize.
      ["    # The pin cannot call bytesize on this value (docs/doom.md); its length is the\n" \
       "    # session's count, and it is read with getbyte, as lib/doom/sight.rb reads it.\n" \
       "    b = lv.reject\n    n = s.count(\"#{name}\")\n    i = 0\n    while i < n\n" \
       "      c = b.getbyte(i)\n      s.put(\"#{name}\", i, c) if c != 0\n      i += 1\n    end\n", %w[lv]]
    elsif (m = org.match(/\Aper-entry:Doom::Wad:(pos|size)\z/))
      ["    n = s.count(\"#{name}\")\n    wad.count == n or raise NativeSessionError, \"#{name}: \#{wad.count} lump(s), the session counts \#{n}\"\n" \
       "    i = 0\n    while i < n\n      s.put(\"#{name}\", i, wad.lump(i).#{m[1]})\n      i += 1\n    end\n", %w[wad]]
    elsif org == "per-entry:Doom::Wad:name:8"
      ["    n = s.count(\"#{name}\")\n    wad.count * 8 == n or raise NativeSessionError, \"#{name}: \#{wad.count} lump(s), the session counts \#{n} byte(s)\"\n" \
       "    i = 0\n    while i < wad.count\n      nm = wad.lump(i).name\n" \
       "      nm.bytesize <= 8 or raise NativeSessionError, \"lump \#{i}'s name is longer than 8\"\n" \
       "      k = 0\n      while k < nm.bytesize\n        c = nm.getbyte(k)\n        s.put(\"#{name}\", i * 8 + k, c) if c != 0\n        k += 1\n      end\n" \
       "      i += 1\n    end\n", %w[wad]]
    elsif (m = org.match(/\Asource-select:(dc|ds):(res|base)\z/))
      pick = m[2] == "res" ? "sel" : "base"
      if m[1] == "dc"
        ["    # Resources' SourceSelect, which accepts job mode 1 only before the first frame.\n" \
         "    buf = r.instance_variable_get(:@dc_srcbuf)\n    ofs = r.instance_variable_get(:@dc_srcofs)\n" \
         "    buf.bytesize == 0 or raise NativeSessionError, \"#{name}: the renderer has set a column source before the first frame\"\n" \
         "    sel = -1\n    base = 0\n    s.put(\"#{name}\", 0, #{pick})\n", %w[r]]
      else
        ["    # Resources' SourceSelect, which accepts job mode 1 only before the first frame.\n" \
         "    buf = r.instance_variable_get(:@ds_source)\n" \
         "    buf.bytesize == 0 or raise NativeSessionError, \"#{name}: the renderer has set a span source before the first frame\"\n" \
         "    sel = -1\n    base = 0\n    s.put(\"#{name}\", 0, #{pick})\n", %w[r]]
      end
    elsif org == "offsets-of:Hud@@texts"
      ["    parts = hud.instance_variable_get(:@texts)\n    n = s.count(\"#{name}\")\n" \
       "    parts.length + 1 == n or raise NativeSessionError, \"#{name}: \#{parts.length} part(s), the session counts \#{n}\"\n" \
       "    at = 0\n    s.put(\"#{name}\", 0, 0)\n    i = 0\n    while i < parts.length\n" \
       "      at += parts[i].bytesize\n      s.put(\"#{name}\", i + 1, at)\n      i += 1\n    end\n", %w[hud]]
    else
      read, cls, value =
        if ((m = org.match(/\A([A-Za-z]+)@@(\w+)\z/)) || (m = org.match(/\ADoom::([A-Za-z]+) @(\w+)\z/))) &&
           m[1] == "KeyScript"
          # THE KEY SCRIPT IS HANDED OVER AS ITS THREE ARRAYS, not as the object:
          # a program run without -script has no KeyScript (KeyScript.new refuses
          # an empty script) and hands three empty arrays, with scriptlines 0.
          o = OBJ.fetch("KeyScript")
          ["ks_#{m[2]}", "ks_#{m[2]}", o.instance_variable_get("@#{m[2]}")]
        elsif (m = org.match(/\A([A-Za-z]+)@@(\w+)\z/)) || (m = org.match(/\ADoom::([A-Za-z]+) @(\w+)\z/))
          o = OBJ.fetch(m[1]) { abort("core-native-prep: #{name}: no object for #{m[1]}") }
          ["#{VAR.fetch(m[1])}.instance_variable_get(:@#{m[2]})", m[1], o.instance_variable_get("@#{m[2]}")]
        elsif (m = org.match(/\ADoom::([A-Za-z]+)#(\w+)(?::(\w+))?\z/))
          o = OBJ.fetch(m[1])
          arg = m[3] ? "(\"#{m[3]}\")" : ""
          ["#{VAR.fetch(m[1])}.#{m[2]}#{arg}", m[1], m[3] ? o.public_send(m[2], m[3]) : o.public_send(m[2])]
        elsif (m = org.match(/\ADoom::(Info|Tables)\.(\w+)\z/))
          ["Doom::#{m[1]}.#{m[2]}", nil, Doom.const_get(m[1]).public_send(m[2])]
        elsif (m = org.match(/\ADoom::(\w+)::([A-Z_]+)\z/))
          ["Doom::#{m[1]}::#{m[2]}", nil, Doom.const_get(m[1]).const_get(m[2])]
        else
          abort("core-native-prep: #{name}: producer #{org} has no generated form")
        end
      sh = shape(value)
      [body_for_value.(name, sh, read), cls ? [VAR.fetch(cls, cls)] : []]
    end
  meth = "p_#{name}"
  methods << "  # #{name}: #{org}\n  def self.#{meth}(#{(%w[s] + params).join(', ')})\n#{code}  end\n"
  calls << "    #{meth}(#{(%w[s] + params).join(', ')})\n"
end

# --- the layout ---------------------------------------------------------------
lit = ->(a) { "[\n" + a.each_slice(8).map { |sl| "    " + sl.join(", ") }.join(",\n") + "\n  ]" }
names = schema.map { |f| f[0].inspect }
roles = schema.map { |f| f[1].inspect }
elems = schema.map { |f| ELEM.fetch(f[2]) }
fixed = schema.map { |f| f[3].start_with?("fixed:") ? Integer(f[3].split(":")[1], 10) : -1 }
cnames = schema.map { |f| (f[3].start_with?("fixed:") ? "" : f[3].split(":", 2)[1]).inspect }
prepd = schema.map { |f| f[4].start_with?("prepared:") ? 1 : 0 }
fills = schema.map { |f| f[4].start_with?("prepared:") ? 0 : Integer(f[4], 10) }
table = ->(n) { rows(File.join(CORE, "entries", n)).map { |f| f[-1].inspect } }

# --- the entries -----------------------------------------------------------------
fields = rows(File.join(CORE, "entries/fields.tsv")).to_h { |e, p, f, _| [[e, p], f] }
DERIVED = { "derived:input-slots.tsv" => "s.input_slots", "derived:step-slots.tsv" => "s.step_slots",
            "derived:render-slots.tsv" => "s.render_slots", "derived:render-zero.tsv" => "s.render_zero" }.freeze
ffi_decls = []
invokes = %w[doom_core_input doom_core_step doom_core_render].map do |e|
  src = File.read(File.join(CORE, "src/doomentry.rb"))
  params = src[/^def #{e}\(([^)]*)\)/m, 1].split(",").map(&:strip).reject { |p| p.start_with?("n_") }
  scalars = params.reject { |p| fields.key?([e, p]) }
  # a scalar's FFI type and the result's storage are the contract's: i32 for
  # an entry at the target's width, i64 for one still at int64 (decision 0022)
  contract = File.readlines(File.join(CORE, "entries", "#{e}.contract"), chomp: true)
  domain = contract.filter_map { |l| f = l.split(" "); [f[1], f[3]] if f[0] == "param" && f[2] == "scalar" }.to_h
  result_t = contract.find { |l| l.start_with?("result ") }.split(" ")[1]
  ffi = { "i32" => ":int32", "i64" => ":int64" }
  types = params.map { |p| fields.key?([e, p]) ? ":int32" : ffi.fetch(domain.fetch(p)) } + [":int32"]
  result_id = result_t == "i32" ? "s.result32" : "s.result"
  read = result_t == "i32" ? "NativeFFI.spinel_adapter_registry_load(s.result32, 0)" : "s.get_i64(s.result, 0)"
  ffi_decls << "      ffi_func :spinel_adapter_#{e}_invoke, [#{types.join(', ')}], :int32\n"
  mod = "NativeFFI"
  args = params.map do |p|
    f = fields[[e, p]]
    next p unless f
    DERIVED.fetch(f) { "s.id(#{f.inspect})" }
  end
  "  def self.#{e}(#{(%w[s] + scalars).join(', ')})\n" \
    "    st = #{mod}.spinel_adapter_#{e}_invoke(\n      #{(args + [result_id]).each_slice(6).map { |sl| sl.join(', ') }.join(",\n      ")})\n" \
    "    st == 0 or raise NativeSessionError, \"#{e} answered \#{st}\"\n" \
    "    #{read}\n  end\n"
end

out = +"# examples/doom/core/full/nativeprep.rb — GENERATED by tools/doom/core-native-prep.rb; do not edit.\n"
out << "#\n# Full's preparation and the three entry calls, for the playable program the pinned\n"
out << "# Spinel compiles. See the generator's header for why each field has its own method.\n"
out << "module Doom\n  module Core\n    module NativePrep\n"
out << "      NAMES = #{lit.(names)}.freeze\n      ROLES = #{lit.(roles)}.freeze\n"
out << "      ELEMENTS = #{lit.(elems)}.freeze\n      COUNT_FIXED = #{lit.(fixed)}.freeze\n"
out << "      COUNT_NAMES = #{lit.(cnames)}.freeze\n      PREPARED = #{lit.(prepd)}.freeze\n      FILLS = #{lit.(fills)}.freeze\n"
out << "      INPUT_SLOTS = #{lit.(table.('input-slots.tsv'))}.freeze\n"
out << "      STEP_SLOTS = #{lit.(table.('step-slots.tsv'))}.freeze\n"
out << "      RENDER_SLOTS = #{lit.(table.('render-slots.tsv'))}.freeze\n"
out << "      RENDER_ZERO = #{lit.(table.('render-zero.tsv'))}.freeze\n"
out << "    end\n\n"
# THE ADAPTER'S C OPERATIONS, declared here rather than through the adapter
# generator's per-entry modules: the registry is shared, the per-entry
# operations are wrappers of it, and a build without the entries links
# examples/doom/native/sp_core_stub.c in their place.
out << "    # The 0007 adapter's registry and the three invokes. Reached through the\n"
out << "    # module name: a bare call inside `def self.` does not resolve on this pin.\n"
out << "    module NativeFFI\n"
out << "      ffi_func :spinel_adapter_registry_startup, [], :int32\n"
out << "      ffi_func :spinel_adapter_registry_allocate, [:int32, :int64], :int32\n"
out << "      ffi_func :spinel_adapter_registry_store, [:int32, :int64, :int64], :int32\n"
out << "      ffi_func :spinel_adapter_registry_load, [:int32, :int64], :int64\n"
out << "      ffi_func :spinel_adapter_registry_store_i64_words, [:int32, :int64, :int64, :int64], :int32\n"
out << "      ffi_func :spinel_adapter_registry_load_i64_words, [:int32, :int64, :int32, :int64, :int64], :int32\n"
out << "      ffi_func :spinel_adapter_registry_release, [:int32], :int32\n"
out << "      # decision 0021: read-only storage the caller placed; the address as :int64\n"
out << "      ffi_func :spinel_adapter_registry_bind, [:int32, :int64, :int64], :int32\n"
out << ffi_decls.join
out << "    end\n  end\nend\n\n"
out << "module Doom\n  module Core\n    module NativePrep\n"
out << "  def self.prepare(s, wad, tx, lv, rnd, g, sp, r, sb, hud, ks_code, ks_from, ks_to, kst, tc, dw, jobs, ex)\n#{calls.join}    0\n  end\n\n"
out << methods.join("\n")
out << "\n" << invokes.join("\n")
out << "    end\n  end\nend\n"
File.write(opt[:out], out)
warn "core-native-prep: #{calls.length} prepared field(s), #{schema.length} schema row(s) -> #{opt[:out]}"
