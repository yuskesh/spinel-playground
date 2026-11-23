# frozen_string_literal: true
#
# examples/doom/core/full/session.rb — decision 0008 task 5's session wrapper.
#
# All allocation belongs to Full. A session owns every buffer the schema
# declares, allocates each ONCE, hands the generated adapters their registry
# IDs, and releases each once.
#
#   session = Doom::Core::Session.open(schema: ..., catalog: ..., prepared: ...)
#   session.id(:game_mobj_x)   # what an adapter is given
#   session.close              # every buffer released, exactly once
#
# TWO SESSIONS SHARE NO MUTABLE STATE. Every allocation is per session, so a
# second session's `game_mobj_x` is a different buffer from the first's. That
# is not a property to hope for: `Session.open` never consults anything
# outside its own instance, and the test writes through one session's buffer
# and reads the other's.
#
# A SESSION IS NOT LIVE UNTIL ITS PRODUCTS ARE CHECKED. Decision 0008: screen
# dimensions and products are checked before a session is made live, and Full
# checks byte-size and address overflow before allocation. Those checks happen
# in `open`, before a single byte is allocated, because a session that has
# allocated half its buffers and then refuses is a session whose release path
# has to know which half.

module Doom
  module Core
    class SessionError < StandardError; end
    # The step Full will not make: see Session#before_step!.
    class RebirthRefused < SessionError; end

    # One declared buffer, as the session holds it.
    Buffer = Struct.new(:name, :role, :element, :count, :bytes, :store,
                        keyword_init: true) do
      def released? = store.nil?
    end

    class Session
      ELEMENT_BYTES = { "u8" => 1, "i8" => 1, "u16" => 2, "i16" => 2, "i32" => 4, "u32" => 4, "i64" => 8 }.freeze
      U64_MAX = 18_446_744_073_709_551_615

      attr_reader :buffers
      attr_accessor :slots

      # `buffers` is the generator's `buffers.tsv`; `prepared` maps a prepared
      # name to the bytes Full has ready for it.
      def self.open(buffers:, prepared: {}, limit_bytes: nil, slots: nil)
        rows = read_buffers(buffers)
        # The slot table is read BEFORE anything is allocated, and has to
        # describe exactly the buffer it indexes.
        slot_rows = slots ? read_slots(slots) : nil
        #
        # AND THE BUFFER HAS TO BE THE ONE THE SLOTS DESCRIBE, whatever produced
        # the manifest: persistent, i64, one cell per slot, and prepared as
        # `core_state` so every slot's own initial arrives in it. Checking the
        # count alone let an i64 slot table open over a u8 buffer, and let the
        # old `core_state ... 0` row open with a -1 slot silently at 0.
        if slot_rows
          shared = rows.select { |r| r["name"] == "core_state" }
          shared.length == 1 or
            raise SessionError, "#{slots} lists #{slot_rows.length} slot(s) and the manifest has " \
                                "#{shared.length} core_state buffer(s)"
          shared = shared.first
          shared["role"] == "persistent" or
            raise SessionError, "core_state is #{shared['role']}; the slot buffer is persistent"
          shared["element"] == "i64" or
            raise SessionError, "core_state is #{shared['element']}; every slot is one i64"
          shared["count"] == slot_rows.length or
            raise SessionError, "core_state holds #{shared['count']} and #{slots} lists " \
                                "#{slot_rows.length} slot(s)"
          shared["initial"] == "prepared:core_state" or
            raise SessionError, "core_state opens as #{shared['initial']}, which would drop each " \
                                "slot's own initial; it must be prepared:core_state"
        end
        s = new(rows, prepared, limit_bytes)
        s.slots = slot_rows ? slot_rows.transform_values { |v| v["index"] } : {}
        s
      end

      SLOT_COLUMNS = %w[field index initial origin].freeze

      # Each scalar field's index in the shared `core_state` buffer, the initial
      # Full puts there, and the field's origin. A scalar is not its own
      # allocation, so a layout that names one has to be told where in that
      # buffer to look -- and Full has to be told what to put there.
      #
      # Every index from 0 to n-1 exactly once, every field once: a gap would be
      # a slot nobody initialised and a repeat would be two fields in one cell.
      def self.read_slots(path)
        out = {}
        by_index = {}
        header = nil
        File.foreach(path).with_index(1) do |ln, i|
          if ln.start_with?("#field")
            header = ln.chomp.delete_prefix("#").split("\t", -1)
            header == SLOT_COLUMNS or
              raise SessionError, "#{path}:#{i}: columns #{header.join(', ')}, want #{SLOT_COLUMNS.join(', ')}"
            next
          end
          next if ln.start_with?("#") || ln.strip.empty?
          f = ln.chomp.split("\t", -1)
          f.length == SLOT_COLUMNS.length or
            raise SessionError, "#{path}:#{i}: #{f.length} column(s), want #{SLOT_COLUMNS.length}"
          field, index, initial, origin = f
          field.empty? and raise SessionError, "#{path}:#{i}: a slot with no field name"
          index =~ /\A(0|[1-9][0-9]*)\z/ or
            raise SessionError, "#{path}:#{i}: #{field}: index #{index.inspect} is not a non-negative integer"
          index = Integer(index, 10)
          out.key?(field) and
            raise SessionError, "#{path}:#{i}: #{field} is listed twice"
          by_index.key?(index) and
            raise SessionError, "#{path}:#{i}: #{field} and #{by_index[index]} both claim slot #{index}"
          initial =~ /\A-?[0-9]+\z/ || initial =~ /\Aprepared:\S+\z/ or
            raise SessionError, "#{path}:#{i}: #{field}: initial #{initial.inspect} is neither an integer nor prepared:NAME"
          by_index[index] = field
          out[field] = { "index" => index, "initial" => initial, "origin" => origin, "line" => i }
        end
        header or raise SessionError, "#{path} has no #field header"
        missing = (0...out.length).reject { |k| by_index.key?(k) }
        missing.empty? or
          raise SessionError, "#{path}: #{out.length} slot(s) and no slot #{missing.first}; " \
                              "indices must be 0 to #{out.length - 1}"
        out
      end

      def self.read_buffers(path)
        rows = []
        File.foreach(path).with_index(1) do |ln, i|
          next if ln.start_with?("#") || ln.strip.empty?
          f = ln.chomp.split("\t", -1)
          f.length == 5 or
            raise SessionError, "#{path}:#{i}: #{f.length} column(s), want 5"
          rows << { "name" => f[0], "role" => f[1], "element" => f[2],
                    "count" => Integer(f[3], 10), "initial" => f[4], "line" => i }
        end
        rows.empty? and raise SessionError, "#{path} declares no buffers"
        rows
      end

      def initialize(rows, prepared, limit_bytes)
        @buffers = {}
        @slots = {}
        @closed = false
        @released = {}

        # EVERY CHECK FIRST, then every allocation. Nothing is allocated until
        # the whole schema is known to be allocatable.
        total = 0
        # Checked against a set built HERE. Asking `@buffers` would ask the map
        # the second loop fills, which is empty while this one runs -- so the
        # duplicate check never fired, and the test that added a duplicate row
        # is what said so.
        declared = {}
        claimed = {}
        rows.each do |r|
          width = ELEMENT_BYTES[r["element"]] or
            raise SessionError, "#{r['name']}: element #{r['element'].inspect} is not one of " \
                                "#{ELEMENT_BYTES.keys.join(', ')}"
          declared.key?(r["name"]) and
            raise SessionError, "#{r['name']} is declared twice"
          declared[r["name"]] = true
          r["count"] >= 0 or raise SessionError, "#{r['name']}: a count may not be negative"
          bytes = r["count"] * width
          bytes <= U64_MAX or
            raise SessionError, "#{r['name']}: #{r['count']} x #{width} bytes leaves u64"
          total += bytes
          if limit_bytes && total > limit_bytes
            raise SessionError, "the session needs #{total} bytes and the limit is #{limit_bytes}"
          end
          if r["initial"].start_with?("prepared:")
            name = r["initial"].sub("prepared:", "")
            # ONE PREPARED NAME BELONGS TO ONE FIELD. `prepared` maps a name to
            # one buffer, so two fields claiming a name get the same bytes and
            # at most one of them can be right.
            #
            # This is not hypothetical. The schema used to name a prepared
            # entry after the COUNT it took its length from, so
            # `level_sector_validcount` and `renderer_sector_validcount` both
            # declared `prepared:numsectors` -- and the originals open at 0 and
            # at -1. Nothing saw it while prepared data was zeros on both sides
            # and prepared fields were left out of the comparison.
            claimed[name] and
              raise SessionError, "prepared:#{name} is claimed by #{claimed[name]} and " \
                                  "#{r['name']}; a prepared name belongs to one field"
            claimed[name] = r["name"]
            data = prepared[name] or
              raise SessionError, "#{r['name']} wants prepared:#{name}, which Full did not prepare"
            data.bytesize == bytes or
              raise SessionError, "prepared:#{name} is #{data.bytesize} bytes and " \
                                  "#{r['name']} declares #{bytes}"
          else
            fill = Integer(r["initial"], 10)
            lo, hi = domain(r["element"])
            (fill >= lo && fill <= hi) or
              raise SessionError, "#{r['name']}: initial #{fill} is outside #{r['element']}"
          end
          r["bytes"] = bytes
        end

        rows.each do |r|
          store =
            if r["initial"].start_with?("prepared:")
              prepared[r["initial"].sub("prepared:", "")].dup
            else
              fill_store(r["element"], r["count"], Integer(r["initial"], 10))
            end
          @buffers[r["name"]] = Buffer.new(
            name: r["name"], role: r["role"], element: r["element"],
            count: r["count"], bytes: r["bytes"], store: store)
        end
      end

      def domain(element)
        case element
        when "u8" then [0, 255]
        when "i32" then [-2_147_483_648, 2_147_483_647]
        when "u32" then [0, 4_294_967_295]
        else [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807]
        end
      end

      def fill_store(element, count, fill)
        return (fill.chr * count).b if element == "u8" && count.positive?
        return "".b if element == "u8"
        Array.new(count, fill)
      end

      # What a generated adapter is given. It is a NAME in this registry, not
      # an address: an address would be a value CORE could hold, and CORE
      # receives 0007 scalars and buffers.
      def id(name)
        @closed and raise SessionError, "the session is closed"
        b = @buffers[name.to_s] or raise SessionError, "#{name} is not a declared buffer"
        b.released? and raise SessionError, "#{name} has been released"
        b
      end

      # THE UNSUPPORTED REBIRTH IS REFUSED BEFORE THE STEP (decision 0008's
      # "explicit pre-step scalar session condition"; the owner's decision of
      # 2026-09-17). A dead player who presses use sets PST_REBORN in one tic,
      # and the original's next G_Ticker raises: level reloading is not
      # implemented. Full reads that state from the session between tics and
      # refuses before calling doom_core_step, so the step is never entered in a
      # state Full could have refused. CORE's own refusal stays behind it as a
      # backstop the shipped program does not reach.
      #
      # It is a read of one core_state cell and a refusal -- nothing else of the
      # step is known here. A caller that gets RebirthRefused fails the session:
      # nothing is presented and nothing is retried.
      PST_REBORN = 2
      PLAYERSTATE = "game_pl_playerstate"

      def self.rebirth_pending?(playerstate) = playerstate == PST_REBORN

      #
      # `read` is how a caller whose storage lives elsewhere -- the adapter's
      # registry, on Full's route (full/route.rb) -- hands over the live cell:
      # it is given the field's name and answers its value. Without it the
      # session's own store is read.
      def before_step!(read: nil)
        @closed and raise SessionError, "the session is closed"
        index = @slots[PLAYERSTATE] or raise SessionError, "the session has no slot for #{PLAYERSTATE}"
        state =
          if read
            read.call(PLAYERSTATE)
          else
            store = id(:core_state).store
            store.is_a?(String) ? store.unpack1("q<", offset: 8 * index) : store[index]
          end
        return unless self.class.rebirth_pending?(state)
        raise RebirthRefused, "rebirth is not supported: the player died and pressed use " \
                              "(#{PLAYERSTATE} is PST_REBORN); the step is not called"
      end

      def bytes_total = @buffers.each_value.sum(&:bytes)

      # Released ONCE. A second release is a defect in the caller and is said
      # so rather than ignored: a release path that tolerates being run twice
      # cannot tell a double release from a leak.
      def close
        @closed and raise SessionError, "the session is already closed"
        @buffers.each_value do |b|
          @released[b.name] = (@released[b.name] || 0) + 1
          b.store = nil
        end
        @closed = true
        @released
      end

      PACK = { "u8" => "C", "i8" => "c", "u16" => "S<", "i16" => "s<", "i32" => "l<", "u32" => "L<", "i64" => "q<" }.freeze

      # The canonical snapshot of this session's storage, in the layout's
      # order. Same rules as the layout: fixed width, little endian, no
      # padding, no addresses, and whatever the layout leaves out -- scratch --
      # is left out here too.
      def snapshot(layout)
        @closed and raise SessionError, "the session is closed"
        out = +"".b
        layout.each do |f|
          b = @buffers[f["field"]]
          if b.nil?
            # A scalar: one i64 at its index in the shared buffer.
            idx = (@slots || {})[f["field"]] or
              raise SessionError, "the layout names #{f['field']}, which is neither a buffer " \
                                  "nor a scalar slot here"
            f["element"] == "i64" && f["count"] == 1 or
              raise SessionError, "#{f['field']} is a scalar slot and the layout says " \
                                  "#{f['count']} x #{f['element']}"
            shared = @buffers["core_state"] or
              raise SessionError, "there is no core_state buffer to hold #{f['field']}"
            # Prepared by Full, so it is BYTES: the slot is the eight at 8*idx.
            # (Indexing a String by idx would read one character.)
            out << if shared.store.is_a?(String)
                     cell = shared.store.byteslice(idx * 8, 8)
                     cell && cell.bytesize == 8 or
                       raise SessionError, "#{f['field']} is slot #{idx} and core_state holds " \
                                           "#{shared.store.bytesize} bytes"
                     cell.b
                   else
                     [shared.store[idx]].pack("q<")
                   end
            next
          end
          b.element == f["element"] or
            raise SessionError, "#{b.name} is #{b.element} and the layout says #{f['element']}"
          b.count == f["count"] or
            raise SessionError, "#{b.name} holds #{b.count} and the layout says #{f['count']}"
          # Prepared data arrives as BYTES and stays bytes whatever its element
          # type; only a buffer this session filled itself holds elements.
          out << if b.store.is_a?(String)
                   b.store.bytesize == f["bytes"] or
                     raise SessionError, "#{b.name} holds #{b.store.bytesize} bytes and " \
                                         "the layout says #{f['bytes']}"
                   b.store.b
                 else
                   b.store.pack(PACK[b.element] + b.count.to_s)
                 end
        end
        out
      end

      def closed? = @closed
      def release_count(name) = @released[name.to_s] || 0
    end
  end
end
