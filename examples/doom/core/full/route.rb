# frozen_string_literal: true
#
# examples/doom/core/full/route.rb — Full's job-mode-1 route through the three
# CORE entries (decision 0008; the owner's render decision (A)).
#
#   route = Doom::Core::Route.open(lib: ..., headers: ..., session: ...)
#   route.tic(t, command, predraws)   # input is the demo's; step, then render
#   route.screen                      # the frame, read back
#   route.close
#
# FULL HOLDS NO POINTERS. Every buffer the session declares is registry storage
# of the 0007 adapter, allocated once at its declared element and count, filled
# from the session's prepared bytes, and handed to an entry as its id through
# the generated `invoke`. The adapter, not this file, refuses overlapping or
# stale participants and poisons the mutable ones when a call fails; a status
# other than 0 ends the route (RouteFailed) and nothing is read back after it.
#
# WHAT FULL WRITES BETWEEN THE ENTRIES is what bin/doom.rb's loop does between
# the calls it makes, and nothing else:
#   * the tic's command into core_command (a demo's four values; the fifth
#     cell is the input entry's angle byte, which a played demo does not use);
#   * the melt wipe's 320 M_Random draws before gametic 2 (`predraws`);
#   * the weapon sprites and the extra light, from the game's fields into the
#     renderer's (Renderer#set_psprite, #set_psprite_flash, #extralight=, whose
#     bodies are those stores);
#   * the render entry's scalars, read off the fields Game's accessors read.
#
# TWO CONDITIONS ARE CHECKED HERE, not assumed:
#   * THE MODE (condition (b)). This route runs the render entry in job mode
#     1, the CRuby comparison lanes' mode; the native program and the board
#     run job mode 0 (decision 0008, 2026-10-21). The mode
#     cell is read back from the registry before EVERY render call and a route
#     whose cell holds another value is refused before the call.
#   * THE REBIRTH (decision 0008's pre-step condition). Session#before_step! is
#     called before every step with a reader over the live registry cell, so
#     the refusal binds to this caller and to the state the step would see.
require "fiddle"
require_relative "session"

module Doom
  module Core
    class RouteError < SessionError; end
    # A call the adapter refused. Its participants are poisoned; the route ends.
    class RouteFailed < RouteError; end

    class Route
      ELEM = { "u8" => 1, "i32" => 2, "u32" => 3, "i64" => 4, "i8" => 5, "u16" => 6, "i16" => 7 }.freeze
      STATUS = { 1 => "ARGUMENT", 2 => "ARITHMETIC", 3 => "BOUNDS", 4 => "CAPACITY" }.freeze
      ENTRIES = %w[doom_core_input doom_core_step doom_core_render].freeze
      # The classification the render entry is built for (the owner's (A)).
      JOB_MODE = 1
      I32 = Fiddle::TYPE_INT
      I64 = Fiddle::TYPE_LONG_LONG
      CORE = File.expand_path("..", __dir__)

      attr_reader :session, :ids, :calls

      # `lib` links the three generated adapters, their registry and the kernel
      # objects; `headers` is the directory the adapter generator wrote.
      def self.open(lib:, headers:, session:)
        new(lib, headers, session)
      end

      # The entry's parameters, in the order its generated invoke takes them:
      # [[name, :id | :scalar, Fiddle type], ...]. Read from the header the
      # generator wrote, so a contract that changes changes this. A buffer is
      # an id (its comment says `the id of`); a scalar's comment names its type,
      # i32 or i64 -- since decision 0022 an entry at the target's width takes
      # i32 scalars, so the C type alone no longer tells them apart.
      def self.signature(headers, entry)
        path = File.join(headers, "spinel_adapter_#{entry}.h")
        text = File.read(path)
        body = text[/int32_t spinel_adapter_#{entry}_invoke\((.*?)\);/m, 1] or
          raise RouteError, "#{path} declares no invoke for #{entry}"
        params = body.scan(%r{(int32_t|int64_t) sp_arg(\d+),?\s*/\* (\w+) ([^*]*)\*/}).map do |t, k, n, note|
          if note.start_with?("-- the id of")
            t == "int32_t" or raise RouteError, "#{path}: #{n} is an id passed as #{t}"
            [Integer(k, 10), n, :id, I32]
          elsif (m = note.match(/\A\((i32|i64)\)/))
            (m[1] == "i32") == (t == "int32_t") or raise RouteError, "#{path}: #{n} says #{m[1]} and is passed as #{t}"
            [Integer(k, 10), n, :scalar, m[1] == "i32" ? I32 : I64]
          else
            raise RouteError, "#{path}: #{n}'s comment names neither an id nor a scalar type"
          end
        end
        params.map(&:first) == (0...params.length).to_a or
          raise RouteError, "#{path}: the invoke's arguments are not sp_arg0..#{params.length - 1}"
        body.include?("int32_t sp_result_id") or raise RouteError, "#{path}: the invoke has no result id"
        params.map { |_, n, kind, type| [n, kind, type] }
      end

      # The entry's result element, i32 or i64, from its contract: the
      # generated invoke refuses result storage of any other element.
      def self.result_element(entry)
        File.read(File.join(CORE, "entries", "#{entry}.contract"))[/^result (i32|i64)$/, 1] or
          raise RouteError, "#{entry}.contract declares no i32 or i64 result"
      end

      def self.table(name)
        File.readlines(File.join(CORE, "entries", name))
            .reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t")[-1] }
      end

      def initialize(lib, headers, session)
        @session = session
        @lib = Fiddle.dlopen(lib)
        fn = ->(name, args, ret) { Fiddle::Function.new(@lib[name], args, ret) }
        @allocate = fn.("spinel_adapter_registry_allocate", [I32, I64], I32)
        @store = fn.("spinel_adapter_registry_store", [I32, I64, I64], I32)
        @load = fn.("spinel_adapter_registry_load", [I32, I64], I64)
        @store_words = fn.("spinel_adapter_registry_store_i64_words", [I32, I64, I64, I64], I32)
        @load_words = fn.("spinel_adapter_registry_load_i64_words", [I32, I64, I32, I64, I64], I32)
        @release = fn.("spinel_adapter_registry_release", [I32], I32)
        fn.("spinel_adapter_registry_startup", [], I32).call.zero? or
          raise RouteError, "the adapter registry would not start"
        @allocated = []
        @words = allocate("u32", 2)
        @results = {}
        @calls = Hash.new(0)
        @failed = nil

        fields = File.readlines(File.join(CORE, "entries", "fields.tsv"))
                     .reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t") }
        @field_of = fields.to_h { |e, p, f, el, _| [[e, p], [f, el]] }
        @ids = {}
        @element = {}
        @entries = {}
        ENTRIES.each do |e|
          sig = self.class.signature(headers, e)
          sig.each do |name, kind, _|
            next unless kind == :id
            row = @field_of[[e, name]] or
              raise RouteError, "#{e}: the header names #{name}, which entries/fields.tsv does not"
            field, element = row
            bind(field, element)
          end
          types = sig.map { |_, _, type| type }
          res = self.class.result_element(e)
          @results[res] ||= allocate(res, 1)
          @entries[e] = [sig, Fiddle::Function.new(@lib["spinel_adapter_#{e}_invoke"], types + [I32], I32), res]
        end
        @jobmode_id = @ids.fetch("renderer_jobmode") { raise RouteError, "the render entry takes no job mode" }
        check_mode!("at session open")
      end

      # One registry buffer per field, whichever entries name it.
      def bind(field, element)
        return if @ids.key?(field)
        if field.start_with?("derived:")
          # An index table: position i holds the core_state slot of row i.
          slots = self.class.table(field.delete_prefix("derived:")).map do |f|
            @session.slots.fetch(f) { raise RouteError, "#{field} names #{f}, which has no core_state slot" }
          end
          id = allocate(element, slots.length)
          slots.each_with_index { |v, i| put(id, element, i, v) }
        else
          b = @session.id(field)
          b.element == element or
            raise RouteError, "#{field} is #{b.element} in the session and #{element} in entries/fields.tsv"
          id = allocate(element, b.count)
          fill(id, b)
        end
        @ids[field] = id
        @element[field] = element
      end

      # Allocated storage is zeroed, so only the non-zero elements are stored.
      def fill(id, buf)
        values =
          if buf.store.is_a?(String)
            buf.store.unpack(Session::PACK.fetch(buf.element) + "*")
          else
            buf.store
          end
        values.length == buf.count or
          raise RouteError, "#{buf.name}: the session holds #{values.length} element(s) and declares #{buf.count}"
        values.each_with_index { |v, i| put(id, buf.element, i, v) unless v.zero? }
      end

      def allocate(element, count)
        id = @allocate.call(ELEM.fetch(element), count)
        id.positive? or raise RouteError, "the adapter would not allocate #{count} #{element}"
        @allocated << id
        id
      end

      def put(id, element, i, v)
        st = element == "i64" ? @store_words.call(id, i, v & 0xffffffff, (v >> 32) & 0xffffffff) : @store.call(id, i, v)
        st.zero? or raise RouteError, "store #{id}[#{i}] = #{v} answered #{STATUS.fetch(st, st)}"
      end

      def get(id, element, i)
        if element == "i64"
          st = @load_words.call(id, i, @words, 0, 1)
          st.zero? or raise RouteError, "load #{id}[#{i}] answered #{STATUS.fetch(st, st)}"
          v = (@load.call(@words, 1) << 32) | @load.call(@words, 0)
          return v >= (1 << 63) ? v - (1 << 64) : v
        end
        v = @load.call(id, i)
        v.negative? and raise RouteError, "load #{id}[#{i}] answered #{STATUS.fetch(-v, v)}"
        %w[i8 i16 i32].include?(element) && v >= (1 << 31) ? v - (1 << 32) : v
      end

      # A resident field's cell, live: a buffer's element or a scalar's slot.
      def read(field, i = 0)
        live!
        return get(@ids.fetch(field), @element.fetch(field), i) if @ids.key?(field)
        slot = @session.slots.fetch(field) { raise RouteError, "#{field} is neither a bound buffer nor a slot" }
        get(@ids.fetch("core_state"), "i64", slot)
      end

      def write(field, value, i = 0)
        live!
        return put(@ids.fetch(field), @element.fetch(field), i, value) if @ids.key?(field)
        slot = @session.slots.fetch(field) { raise RouteError, "#{field} is neither a bound buffer nor a slot" }
        put(@ids.fetch("core_state"), "i64", slot, value)
      end

      def check_mode!(where)
        mode = get(@jobmode_id, @element.fetch("renderer_jobmode"), 0)
        mode == JOB_MODE or
          raise RouteError, "the render entry is classified for job mode #{JOB_MODE} and " \
                            "renderer_jobmode holds #{mode} #{where}; the render is not called"
      end

      def live!
        @failed and raise RouteFailed, "the route ended: #{@failed}"
      end

      # Whether a call has ended this route. Its participants are poisoned, so
      # a lane asks this rather than reading anything back.
      def failed? = !@failed.nil?

      def invoke(entry, scalars)
        live!
        sig, f, res = @entries.fetch(entry)
        args = sig.map do |name, kind, _|
          next @ids.fetch(@field_of.fetch([entry, name]).first) if kind == :id
          scalars.fetch(name) { raise RouteError, "#{entry}: no value for scalar #{name}" }
        end
        (scalars.keys - sig.map(&:first)).empty? or
          raise RouteError, "#{entry} takes no #{(scalars.keys - sig.map(&:first)).join(', ')}"
        @calls[entry] += 1
        status = f.call(*args, @results.fetch(res))
        unless status.zero?
          @failed = "#{entry} answered #{STATUS.fetch(status, status)} (#{status}) on call #{@calls[entry]}"
          raise RouteFailed, @failed
        end
        get(@results.fetch(res), res, 0)
      end

      # THE STEP HALF OF A TIC: the tic's command written into core_command,
      # Full's pre-step condition over the live cell, and doom_core_step.
      # Answers the gametic the entry answered.
      #
      # A lane that compares state and draws no frame calls this and not #tic
      # (tests/doom-core/native-scenario-diff.rb); #tic is this call and then
      # the frame, which is what the played program does.
      def step(command, predraws)
        command.length == 4 or raise RouteError, "a demo command is four values"
        (command + [0]).each_with_index { |v, i| write("core_command", v, i) }
        @session.before_step!(read: ->(field) { read(field) })
        invoke("doom_core_step", "predraws" => predraws)
      end

      # One tic of a played demo: the step, then the frame. Answers
      # [gametic, frame].
      def tic(t, command, predraws)
        gametic = step(command, predraws)
        write("renderer_psp_state", read("game_psp_state", 0))
        write("renderer_psp_sx", read("game_psp_sx", 0))
        write("renderer_psp_sy", read("game_psp_sy", 0))
        write("renderer_psp1_state", read("game_psp_state", 1))
        write("renderer_psp1_sx", read("game_psp_sx", 1))
        write("renderer_psp1_sy", read("game_psp_sy", 1))
        write("renderer_extralight", read("game_pl_extralight"))
        m = read("game_player_mo")
        scalars = {
          "first" => t.zero? ? 1 : 0,
          "health" => read("game_pl_health"),
          "armorpoints" => read("game_pl_armorpoints"),
          "ammokind" => read("game_weapon_ammo", read("game_pl_readyweapon")),
          "viewx" => read("game_mobj_x", m), "viewy" => read("game_mobj_y", m),
          "viewz" => read("game_pl_viewz"), "viewangle" => read("game_mobj_angle", m)
        }
        check_mode!("before frame #{@calls['doom_core_render'] + 1}")
        frame = invoke("doom_core_render", scalars)
        [gametic, frame]
      end

      def screen = cells("renderer_screen").pack("C*")

      # Every element of a field, live.
      def cells(field)
        live!
        if @ids.key?(field)
          id = @ids.fetch(field)
          element = @element.fetch(field)
          return Array.new(@session.id(field).count) { |i| get(id, element, i) }
        end
        [read(field)]
      end

      # The canonical bytes of the layout's rows (Reference.read_layout's
      # shape), read back from the registry. A field no entry names was never
      # handed to CORE, so it is the session's own and read from there.
      def snapshot(rows)
        out = +"".b
        rows.each do |f|
          name = f["field"]
          values =
            if @ids.key?(name) || @session.slots.key?(name) then cells(name)
            else
              b = @session.id(name)
              b.store.is_a?(String) ? b.store.unpack(Session::PACK.fetch(b.element) + "*") : b.store
            end
          values.length == f["count"] or
            raise RouteError, "#{name}: #{values.length} element(s) and the layout says #{f['count']}"
          out << values.pack(Session::PACK.fetch(f["element"]) + "*")
        end
        out
      end

      def bound?(field) = @ids.key?(field)

      # Every id this route allocated, released once. Answers the number that
      # refused.
      def close
        @allocated.count { |id| !@release.call(id).zero? }
      end
    end
  end
end
