# frozen_string_literal: true
#
# examples/doom/core/full/reference.rb — decision 0008 task 5's reference route.
#
# The old Full setup and the new prepared state, built from the SAME WAD and
# configuration, and compared cell by cell before the first tick.
#
#   ref = Doom::Core::Reference.snapshot(session: ..., layout: ..., objects: ...)
#
# WHAT THIS IS FOR. The schema says `Game@@mobj_x` is 4096 i64 initialised to
# zero. The reference is the real `Doom::Game`, built the way `bin/doom.rb`
# builds it. If the two disagree about a single cell before anything has run,
# the schema describes a different game -- and finding that out before the
# first tick is much cheaper than finding it out as a frame that differs on
# tic 3830.
#
# WHAT IT COMPARES AND WHAT IT CANNOT. Only DEFINED initialised cells: a
# `scratch` field's bytes are undefined between calls, and the snapshot layout
# already excludes it. A field whose reference object does not expose it --
# no accessor, no ivar of that name -- is reported as UNREACHABLE rather than
# silently skipped, because a field nobody can read from the reference is a
# field this comparison says nothing about, and saying nothing is not the same
# as agreeing.

module Doom
  module Core
    module Reference
      class ReferenceError < StandardError; end

      WIDTH = { "u8" => 1, "i8" => 1, "u16" => 2, "i16" => 2, "i32" => 4, "u32" => 4, "i64" => 8 }.freeze
      PACK = { "u8" => "C", "i8" => "c", "u16" => "S<", "i16" => "s<", "i32" => "l<", "u32" => "L<", "i64" => "q<" }.freeze

      # Read one field out of a reference object. The schema's `origin` is
      # `Class@@ivar`, so the ivar is what is read -- through the object's own
      # accessor when it has one, and through instance_variable_get when it
      # does not, which is the same value by a route that does not depend on
      # the class having chosen to expose it.
      def self.field_value(objects, origin)
        cls, ivar = origin.split("@@", 2)
        return [:unreachable, "no @@ in #{origin.inspect}"] if ivar.nil?
        # A LUMP IS ONE DIRECTORY ENTRY PER LUMP, so `Lump@@pos` is not one
        # value to read off one object -- there is no such object -- but one per
        # entry of the original wad, in entry order. That is a fact about the
        # original, so the reference reads it here from the wad it built.
        #
        # WRITTEN HERE, NOT SHARED WITH FULL. `Resources` produces the same
        # arrays on the other side of the comparison. If both called one
        # routine, a mistake in it -- padding a name with the raw slot's
        # trailing bytes, say -- would agree with itself; so the name here is
        # built independently: `Lump#name` is what `Bytes.name8` read, which
        # stops at the first NUL, and it is zero-padded to eight bytes.
        if cls == "Lump"
          wad = objects["Wad"]
          return [:unreachable, "no reference Wad to read the directory from"] if wad.nil?
          entries = Array.new(wad.count) { |i| wad.lump(i) }
          case ivar
          when "pos"  then return [:ok, entries.map(&:pos)]
          when "size" then return [:ok, entries.map(&:size)]
          when "name"
            return [:ok, entries.map do |l|
              n = l.name.b
              raise ReferenceError, "lump #{l.index} name is #{n.bytesize} bytes" if n.bytesize > 8
              n + ("\0".b * (8 - n.bytesize))
            end.join.b]
          end
          return [:unreachable, "a Lump has no #{ivar} the directory records"]
        end
        # THE SOURCE ALIASES AS A SELECTOR AND A BASE (docs/core/doom-source-alias.md).
        # The original holds a reference to the buffer a column or span reads; the
        # schema holds which resource that is -- RES_NONE -1, RES_ATLAS 0, RES_WAD 1,
        # RES_ZONE 2, RES_FLAT 3 -- and a base into it. Converted HERE from the
        # original renderer, apart from Resources: compared against its arrays
        # directly (`@texdata`, `@flatdata`), not through its accessors. Not
        # `@dc_srcres` read as is: the original sets it only on masked paths.
        if cls == "Renderer" && %w[dc_srcres dc_srcbase ds_source ds_source.base].include?(ivar)
          r = objects["Renderer"]
          return [:unreachable, "no reference Renderer for #{origin}"] if r.nil?
          # Job mode 1 only before the first frame, as Full's own conversion
          # (resources.rb, SourceSelect): after one, job mode 1 has left the
          # direct path's references behind on some paths, and these cells are
          # compared at session open only (tests/doom-core/route-lane.rb).
          case r.instance_variable_get(:@jobmode).to_i
          when 0 then nil
          when 1
            unless r.instance_variable_get(:@dc_srcbuf).empty? && r.instance_variable_get(:@ds_source).empty?
              # AFTER A FRAME, THE BASE IS THE ORIGINAL'S OWN. Job mode 1 sets
              # @dc_srcbase on every column path (render.rb:1373, 1926, 2354,
              # 2361), and render-diff compared it with the port's on each of
              # DEMO1-3's 10996 frames: 0 differed. The other three are compared
              # at session open only (tests/doom-core/route-lane.rb).
              return [:ok, r.instance_variable_get(:@dc_srcbase)] if ivar == "dc_srcbase"
              raise ReferenceError, "#{origin}: job mode 1 is converted before the first frame only"
            end
          else
            raise ReferenceError, "#{origin}: the conversion is for job modes 0 and 1"
          end
          tx = r.instance_variable_get(:@textures)
          if ivar.start_with?("dc_")
            buf = r.instance_variable_get(:@dc_srcbuf)
            ofs = r.instance_variable_get(:@dc_srcofs)
            texdata = tx.instance_variable_get(:@texdata)
            sel, base =
              if buf.empty? then [-1, 0]
              elsif buf.equal?(r.instance_variable_get(:@wad_data)) then [1, ofs]
              elsif buf.equal?(r.instance_variable_get(:@zonewin)) then [2, ofs]
              elsif (t = texdata.index { |d| d.equal?(buf) })
                [0, tx.instance_variable_get(:@tex_atlas_base)[t] + ofs]
              else
                raise ReferenceError, "#{origin}: @dc_srcbuf is none of the column resources"
              end
            return [:ok, ivar == "dc_srcres" ? sel : base]
          end
          buf = r.instance_variable_get(:@ds_source)
          flatdata = tx.instance_variable_get(:@flatdata)
          sel, base =
            if buf.empty? then [-1, 0]
            elsif (k = flatdata.index { |d| d.equal?(buf) }) then [3, k * 4096]
            else
              raise ReferenceError, "#{origin}: @ds_source is none of the flats"
            end
          return [:ok, ivar == "ds_source" ? sel : base]
        end
        # WHERE EACH HUD MESSAGE STARTS in the joined `hud_texts`, and where the
        # last ends. Read off the original Hud's own @texts and summed HERE, apart
        # from Resources, which derives the same offsets on the other side.
        if cls == "Hud" && ivar == "texts.ofs"
          hud = objects["Hud"]
          return [:unreachable, "no reference Hud for #{origin}"] if hud.nil?
          at = 0
          return [:ok, [0] + hud.instance_variable_get(:@texts).map { |t| at += t.b.bytesize }]
        end
        obj = objects[cls]
        return [:unreachable, "no reference object for #{cls}"] if obj.nil?
        name = "@#{ivar}"
        unless obj.instance_variables.include?(name.to_sym)
          return [:unreachable, "#{cls} has no #{name}"]
        end
        [:ok, obj.instance_variable_get(name)]
      end

      # The canonical bytes for one field's value, in the layout's element
      # type. A value the element cannot hold is an error rather than a
      # truncation: truncating here would make the comparison agree about a
      # number neither side holds.
      # THE i32-bits FIELDS (examples/doom/core/widths-repr.tsv, decision 0022
      # section 2.4): an angle the original holds as a word 0..2**32-1 is held
      # in its i32 cell as the signed pattern. Read here from the table, and
      # converted here, apart from Resources, which converts on its own.
      I32_BITS = File.readlines(File.expand_path("../widths-repr.tsv", __dir__), chomp: true)
                     .reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.split("\t") }
                     .select { |row| row[1] == "i32-bits" }.map(&:first).freeze

      # THE i32-bits SLOTS (examples/doom/core/state-repr.tsv): core_state's
      # angle slots hold the signed pattern too, in their i64 cells. A row that
      # is no slot of an entry's slot table, or names a slot twice, is refused.
      def self.state_repr(path = File.expand_path("../state-repr.tsv", __dir__),
                          entries = File.expand_path("../entries", __dir__))
        slots = Dir[File.join(entries, "*-slots.tsv")].flat_map do |f|
          File.readlines(f, chomp: true).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.split("\t")[2] }
        end
        seen = {}
        File.readlines(path, chomp: true).each_with_index.filter_map do |l, i|
          next if l.start_with?("#") || l.strip.empty?

          name, repr, = l.split("\t")
          at = "#{File.basename(path)}:#{i + 1}"
          repr == "i32-bits" or raise ReferenceError, "#{at}: #{name}: representation #{repr.inspect} is not i32-bits"
          seen[name] and raise ReferenceError, "#{at}: #{name} is named twice (first at line #{seen[name]})"
          slots.include?(name) or raise ReferenceError, "#{at}: #{name} is no slot of an entry's slot table"
          seen[name] = i + 1
          name
        end
      end
      I32_BITS_SLOTS = state_repr.freeze

      # Whether the port holds this field, an angle buffer or an angle slot, as
      # the signed pattern; the tools that hand the original's values to the
      # port and compare its answers (tests/doom-core/step-diff.rb,
      # render-diff.rb) read it here, as the snapshot does.
      def self.i32_bits?(field) = I32_BITS.include?(field) || I32_BITS_SLOTS.include?(field)

      # The original's 32-bit word as that signed pattern; anything else is
      # refused, not wrapped.
      def self.pattern(v)
        (v.is_a?(Integer) && v >= 0 && v <= 4_294_967_295) or raise ReferenceError, "#{v.inspect} is not a 32-bit word"
        v >= 2_147_483_648 ? v - 4_294_967_296 : v
      end

      # bits32: :buffer for an angle buffer (its element i32), :slot for an
      # angle slot (its cell i64)
      def self.encode(value, element, count, bits32: false)
        w = WIDTH[element] or raise ReferenceError, "element #{element.inspect}"
        items =
          case value
          when Array
            # A flag array holds true and false; 0008 stores flags numerically
            # as 0 and 1. A string array is a prepared byte resource Full
            # flattens into one buffer, so it flattens the same way here.
            if element == "u8" && value.first.is_a?(String)
              value.join.bytes
            else
              value.map { |v| v == true ? 1 : (v == false ? 0 : v) }
            end
          when String then value.bytes
          when Integer then [value]
          when true then [1]
          when false then [0]
          # A PRESENT IVAR HOLDING nil IS AN ERROR, not an absence. It used
          # to return nil here, which made `snapshot` fall through to the
          # schema's initial bytes WITHOUT recording anything -- so a field
          # the original holds as nil silently became whatever the schema
          # said it should be, and then "agreed" with a session built from
          # that same initial. Mac review of 4a8ba23 found it: a present ivar
          # of nil against initial 123 returned 123 with `errors` empty.
          when nil
            raise ReferenceError,
                  "the original holds nil, which no element type can carry; " \
                  "a nil here is a field the reference cannot speak for"
          else raise ReferenceError, "a #{value.class} is not a stored value"
          end
        return nil if items.nil?
        # A SHAPE MISMATCH IS REFUSED, NOT RESHAPED.
        #
        # This used to read
        #     items = items.first(count)
        #     items += [0] * (count - items.length) if items.length < count
        # which TRUNCATED an original longer than the schema says and
        # ZERO-PADDED one that was shorter -- changing the original before
        # comparing against it, which is the one thing an oracle may not do.
        #
        # Mac review of 270fa5a measured what that was hiding and it
        # reproduced here exactly: 166 fields truncated, 16 zero-padded. The
        # extremes say it best -- an original of 4,196,020 elements compared
        # against a schema count of 1, and an empty one padded out to 65,536
        # zeros. Fields reshaped that far can then "agree" on bytes neither
        # side ever held.
        #
        # Refusing puts the field in `errors`, which tests/doom-core/state.sh
        # requires to be zero, so a count that does not match the original is
        # now a failure that names the field instead of a silent reshape. The
        # counts themselves are what has to be fixed; this stops the encoder
        # from covering for them.
        unless items.length == count
          raise ReferenceError,
                "shape: the original holds #{items.length} element(s) and the schema " \
                "declares #{count}; refusing to " +
                (items.length > count ? "truncate it" : "zero-pad it")
        end
        if bits32
          cell = bits32 == :slot ? "i64" : "i32"
          element == cell or raise ReferenceError, "an i32-bits field in element #{element}, not #{cell}"
          items = items.each_with_index.map do |v, i|
            (v.is_a?(Integer) && v >= 0 && v <= 4_294_967_295) or
              raise ReferenceError, "element #{i} is #{v.inspect}, not a 32-bit word"
            pattern(v)
          end
        end
        lo, hi = domain(element)
        items.each_with_index do |v, i|
          v.is_a?(Integer) or
            raise ReferenceError, "element #{i} is a #{v.class}, not an Integer"
          (v >= lo && v <= hi) or
            raise ReferenceError, "element #{i} is #{v}, outside #{element}"
        end
        items.pack(PACK[element] + "#{count}")
      end

      def self.domain(element)
        case element
        when "u8" then [0, 255]
        when "i8" then [-128, 127]
        when "u16" then [0, 65_535]
        when "i16" then [-32_768, 32_767]
        when "i32" then [-2_147_483_648, 2_147_483_647]
        when "u32" then [0, 4_294_967_295]
        else [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807]
        end
      end

      Result = Struct.new(:bytes, :unreachable, :errors, :added, keyword_init: true)

      # The snapshot the comparator reads, built from the reference objects in
      # the layout's order. Fields the reference cannot supply are reported,
      # and their bytes are left at the schema's initial value so the snapshot
      # still has the layout's length -- a short snapshot would be refused by
      # length and would say nothing about the fields that ARE comparable.
      def self.snapshot(layout:, origins:, objects:, initial: nil)
        out = +"".b
        unreachable = []
        added = []
        errors = []
        layout.each do |f|
          name, element, count = f["field"], f["element"], f["count"]
          bytes = count * WIDTH[element]
          origin = origins[name]
          # A FIELD NO IVAR HOLDS (tools/doom/core-added.tsv, origin `added:KEY`) has
          # no original to read: the port's stack, command buffer or frame counter.
          # It opens at the schema's fill on both sides, and is counted apart --
          # neither read nor unreachable.
          if origin.to_s.start_with?("added:")
            added << name
            out << (initial ? initial.byteslice(out.bytesize, bytes) : "\0".b * bytes)
            next
          end
          if origin.nil?
            unreachable << "#{name} (the schema gives it no origin)"
            out << (initial ? initial.byteslice(out.bytesize, bytes) : "\0".b * bytes)
            next
          end
          state, value = field_value(objects, origin)
          if state == :unreachable
            unreachable << "#{name} (#{value})"
            out << (initial ? initial.byteslice(out.bytesize, bytes) : "\0".b * bytes)
            next
          end
          begin
            bits32 = if I32_BITS.include?(name) then :buffer
                     elsif I32_BITS_SLOTS.include?(name) then :slot
                     else false
                     end
            enc = encode(value, element, count, bits32: bits32)
          rescue ReferenceError => e
            errors << "#{name}: #{e.message}"
            enc = nil
          end
          out << (enc || (initial ? initial.byteslice(out.bytesize, bytes) : "\0".b * bytes))
        end
        Result.new(bytes: out, unreachable: unreachable, errors: errors, added: added)
      end

      # The layout as tests/doom-core/compare-state.rb reads it.
      def self.read_layout(path)
        rows = []
        File.foreach(path) do |ln|
          next if ln.start_with?("#") || ln.strip.empty?
          f = ln.chomp.split("\t", -1)
          rows << { "field" => f[0], "element" => f[1],
                    "count" => Integer(f[2], 10), "bytes" => Integer(f[3], 10),
                    "offset" => Integer(f[4], 10) }
        end
        rows
      end

      # The schema's `#alias` lines: [ivar, field, the field's origin]. An ivar
      # named there has no field of its own because it IS that field's storage.
      def self.read_aliases(path)
        File.foreach(path).filter_map do |ln|
          next unless ln.start_with?("#alias\t")
          f = ln.chomp.split("\t", -1)
          f.length == 4 or raise ReferenceError, "#{path}: an #alias line has #{f.length} column(s), want 4"
          f[1..3]
        end
      end

      # AN ALIAS IS A CLAIM ABOUT THE ORIGINAL, so it is checked on the original's
      # objects: the ivar and the field's origin must be ONE object. Equal bytes
      # are not enough -- two copies of the ring agree until the renderer writes
      # one of them -- so the test is identity. Answers the number checked;
      # raises naming the first that is not.
      def self.check_aliases(aliases, objects)
        aliases.each do |src, field, origin|
          s_state, s_val = field_value(objects, src)
          s_state == :ok or raise ReferenceError, "#{src}: #{s_val}"
          t_state, t_val = field_value(objects, origin)
          t_state == :ok or raise ReferenceError, "#{origin}: #{t_val}"
          s_val.equal?(t_val) or
            raise ReferenceError, "#{src} is not the storage of #{field} (#{origin}): the original holds two objects"
        end
        aliases.length
      end

      # A REFERENCE OBSERVES THE PROGRAM'S OBJECTS; IT DOES NOT BUILD ITS OWN.
      #
      # build-prepared.rb and build-reference.rb each constructed a Jobs and a
      # JobExecutor of their own, sized by the screen, while the program's are
      # the renderer's, sized by the view (render.rb:465). Both sides of
      # state.sh read the same fabricated object and agreed.
      #
      # The roots are the classes examples/doom/bin/doom.rb constructs in its
      # main, read from its syntax tree. Every other object handed to a
      # reference must be the very object (`equal?`) a root holds in an ivar.
      # Answers the number of non-root objects checked; raises naming the first
      # that no root holds.
      #
      # WHAT IT DOES NOT CHECK: the arguments a root was built with. It checks
      # where an object came from, not how. A Renderer made with another
      # setblocks, or a DemoWriter with other limits, is a root all the same and
      # passes -- and so does everything it holds: the Renderer at setblocks 11
      # holds a Jobs sized by the screen, and handed over as THE Renderer, that
      # Jobs passes. That is a narrower form of the very defect this guards
      # against (a reference standing for a program it does not match), and
      # nothing here catches it. Each builder states the one configuration it
      # was tested at; agreeing with that is on the builder, not on this check.
      PROGRAM = File.expand_path("../../bin/doom.rb", __dir__)

      def self.program_roots(path = PROGRAM)
        require "prism"
        main = nil
        stack = [Prism.parse_file(path).value]
        until stack.empty? || main
          n = stack.pop
          main = n if n.is_a?(Prism::DefNode) && n.name == :main
          stack.concat(n.compact_child_nodes)
        end
        main or raise ReferenceError, "#{path} defines no main"
        roots = []
        stack = [main]
        until stack.empty?
          n = stack.pop
          # `Doom::X.new`, read off the source span so it holds whichever
          # accessors this Prism gives a constant path.
          if n.is_a?(Prism::CallNode) && n.name == :new && n.receiver.is_a?(Prism::ConstantPathNode) &&
             (m = n.receiver.slice.match(/\ADoom::([A-Z]\w*)\z/))
            roots << m[1]
          end
          stack.concat(n.compact_child_nodes)
        end
        roots.empty? and raise ReferenceError, "#{path}'s main constructs nothing under Doom"
        roots.uniq
      end

      def self.check_graph(objects, roots: program_roots)
        short = ->(o) { o.class.name.split("::").last }
        # ONE OBJECT PER CLASS, UNDER ITS OWN NAME. A reference reads a field
        # by the key its origin names, so an object under another class's key,
        # or a second root under a key nothing reads, is refused here rather
        # than trusted: the second would let anything it holds pass below.
        objects.each do |key, o|
          key.to_s.delete_prefix("Doom::") == short.(o) or
            raise ReferenceError, "#{key} holds a #{short.(o)}; each object is handed over under its own class's name"
        end
        held = objects.values.select { |o| roots.include?(short.(o)) }
        others = objects.values.reject { |o| roots.include?(short.(o)) }
        others.each do |o|
          held.any? { |r| r.instance_variables.any? { |iv| r.instance_variable_get(iv).equal?(o) } } or
            raise ReferenceError, "#{short.(o)} is not the program's: bin/doom.rb does not construct one " \
                                  "and no object it constructs holds this one"
        end
        others.length
      end

      # name -> the schema's `origin` column.
      def self.read_origins(path)
        out = {}
        File.foreach(path) do |ln|
          next if ln.start_with?("#") || ln.strip.empty?
          f = ln.chomp.split("\t", -1)
          out[f[0]] = f[5]
        end
        out
      end
    end
  end
end
