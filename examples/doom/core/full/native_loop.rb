# examples/doom/core/full/native_loop.rb — bin/doom.rb's tic, through the three entries.
#
# bin/doom.rb -core plays through decision 0008's entries. Before the first
# tic it builds the original objects exactly as it always has, and Full's
# preparation (nativeprep.rb) copies their state into the session
# (native_session.rb). From then on each tic is the input entry (when not
# playing a demo), the step entry and the render entry, and between the calls
# Full writes only what bin/doom.rb's own loop writes: the tic's command, the
# melt wipe's 320 draws, the weapon sprites and extra light, and the render
# entry's scalars read back from the fields (full/route.rb does the same in
# CRuby).
#
# THE ORIGINAL OBJECTS ARE SEALED once the session is open (SealedOriginals).
# The loop is handed the session and the seal and nothing else, and the seal
# refuses to give the game or the renderer back. A call to g_ticker or
# render_player_view after the session opens can then only happen through the
# seal, and it refuses: tests/doom-core/native.sh plants such a call on the
# live loop path and requires that refusal.
#
# TWO CHECKS ARE MADE BETWEEN CALLS, as in full/route.rb:
#   * the render entry is classified for job mode 0; the mode cell is read back
#     before every frame and anything else is refused before the call;
#   * a pending rebirth (game_pl_playerstate is PST_REBORN) is refused before
#     the step, on the live cell (Session#before_step!'s condition).
module Doom
  module Core
    class SealedOriginals
      def initialize(game, renderer)
        @game = game
        @renderer = renderer
        @sealed = false
      end

      def seal
        @sealed = true
      end

      def game
        if @sealed
          raise NativeSessionError, "the original game was reached after the session opened; " \
                                    "the playable program runs the tic only through the entries"
        end
        @game
      end

      def renderer
        if @sealed
          raise NativeSessionError, "the original renderer was reached after the session opened; " \
                                    "the playable program draws only through the entries"
        end
        @renderer
      end
    end

    module NativeLoop
      JOB_MODE = 0 # the direct path (decision 0008, the owner's choice of 2026-10-21)
      PST_REBORN = 2
      DEMOMARKER = 0x80

      def self.check_mode(s, frame)
        m = s.get("renderer_jobmode", 0)
        if m != JOB_MODE
          raise NativeSessionError, "the render entry is classified for job mode #{JOB_MODE} and " \
                                    "renderer_jobmode holds #{m} before frame #{frame}; the render is not called"
        end
      end

      def self.before_step(s)
        if s.get("game_pl_playerstate", 0) == PST_REBORN
          raise NativeSessionError, "rebirth is not supported: the player died and pressed use " \
                                    "(game_pl_playerstate is PST_REBORN); the step is not called"
        end
      end

      def self.demo_command(s, fwd, side, aturn, btn)
        s.put("core_command", 0, fwd)
        s.put("core_command", 1, side)
        s.put("core_command", 2, aturn)
        s.put("core_command", 3, btn)
        s.put("core_command", 4, 0)
      end

      # bin/doom.rb's read_keys, into the input entry's key table.
      def self.keys(s, video)
        i = 0
        while i < 256
          s.put("key_state_down", i, 0)
          i += 1
        end
        codes = Doom::TiccmdBuilder::WATCHED_KEYS
        i = 0
        while i < codes.length
          s.put("key_state_down", codes[i], 1) if video.key(codes[i]) != 0
          i += 1
        end
      end

      def self.input(s, scripted, tic, recording)
        NativePrep.doom_core_input(s, scripted, tic, recording)
      end

      def self.step(s, t)
        before_step(s)
        NativePrep.doom_core_step(s, t == 2 ? 320 : 0)
      end

      def self.render(s, t, frame)
        s.put("renderer_psp_state", 0, s.get("game_psp_state", 0))
        s.put("renderer_psp_sx", 0, s.get("game_psp_sx", 0))
        s.put("renderer_psp_sy", 0, s.get("game_psp_sy", 0))
        s.put("renderer_psp1_state", 0, s.get("game_psp_state", 1))
        s.put("renderer_psp1_sx", 0, s.get("game_psp_sx", 1))
        s.put("renderer_psp1_sy", 0, s.get("game_psp_sy", 1))
        s.put("renderer_extralight", 0, s.get("game_pl_extralight", 0))
        m = s.get("game_player_mo", 0)
        health = s.get("game_pl_health", 0)
        armor = s.get("game_pl_armorpoints", 0)
        ammokind = s.get("game_weapon_ammo", s.get("game_pl_readyweapon", 0))
        vx = s.get("game_mobj_x", m)
        vy = s.get("game_mobj_y", m)
        vz = s.get("game_pl_viewz", 0)
        va = s.get("game_mobj_angle", m)
        check_mode(s, frame)
        NativePrep.doom_core_render(s, t == 0 ? 1 : 0, health, armor, ammokind, vx, vy, vz, va)
      end

      def self.screen(s, buf, n)
        i = 0
        while i < n
          buf.setbyte(i, s.get("renderer_screen", i))
          i += 1
        end
      end

      # DemoWriter#save, over the session's buffer and count.
      def self.save_recording(s, path)
        n = s.get("demo_writer_n", 0)
        len = Doom::Demo::HEADER + n * 4
        buf = Doom::Bytes.buffer(len + 1, 0)
        i = 0
        while i < len
          buf.setbyte(i, s.get("demo_writer_buf", i))
          i += 1
        end
        buf.setbyte(len, DEMOMARKER)
        File.open(path, "wb") { |f| f.write(buf) }
        n
      end
    end
  end
end
