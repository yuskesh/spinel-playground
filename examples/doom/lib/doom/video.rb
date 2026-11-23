# doom/lib/doom/video.rb
#
# The interface to SDL2. **Only this file is Spinel-specific**:
# CRuby has no `ffi_func`, so a program that `require_relative`s this does not run
# under CRuby. So it is cut this way:
#
#   - game logic and drawing (`game.rb` / `render.rb` / ...) depend on nothing here
#   - programs that keep the CRuby differential (a pillar of the conventions; `sim_demo.rb` /
#     `record_demo.rb`) do not require this file
#   - only the interactive `bin/doom.rb` goes through here
#
# (a consequence of the convention "require only what you use").
#
# The interface is designed like the IREE experiment's `sp_gpu_shim.c`:
# **an int64 handle + failure as the return value + the message fetched afterwards**.
# The conversion from 8-bit indices to RGB and the table that plays `gamekeydown[]` live in
# `tools/sp_sdl_shim.c` (the C side). The Ruby side allocates not one byte.

require_relative "errors"

module Doom
  # 1:1 with the declarations in `tools/sp_sdl_shim.c`. This is the whole interface.
  module Sdl
    ffi_func :sp_sdl_open,        [:str, :int, :int, :int], :int64
    ffi_func :sp_sdl_close,       [:int64],                 :void
    ffi_func :sp_sdl_set_palette, [:int64, :str],           :int
    ffi_func :sp_sdl_present,     [:int64, :str],           :int
    ffi_func :sp_sdl_save_bmp,    [:int64, :str],           :int
    ffi_func :sp_sdl_pump,        [:int64],                 :int
    ffi_func :sp_sdl_key,         [:int64, :int],           :int
    ffi_func :sp_sdl_us,          [:int64],                 :int64
    ffi_func :sp_sdl_delay,       [:int],                   :void
    ffi_func :sp_sdl_error,       [],                       :str
  end

  # One window + a palette + key state.
  class Video
    def initialize(title, w, h, scale)
      @handle = Sdl.sp_sdl_open(title, w, h, scale)
      raise VideoError, "SDL window: #{Sdl.sp_sdl_error}" if @handle == 0
      @w = w
      @h = h
    end

    # One PLAYPAL plane (768 bytes). `Doom::Palette#plane` can be passed as it is.
    def palette=(pal768)
      raise VideoError, "SDL palette: #{Sdl.sp_sdl_error}" if
        Sdl.sp_sdl_set_palette(@handle, pal768) != 0
    end

    # Puts out one 8-bit index plane (w*h bytes).
    def present(indexed)
      raise VideoError, "SDL present: #{Sdl.sp_sdl_error}" if
        Sdl.sp_sdl_present(@handle, indexed) != 0
    end

    # Leaves evidence for checking by eye (works headless too).
    def save_bmp(path)
      raise VideoError, "SDL save: #{Sdl.sp_sdl_error}" if
        Sdl.sp_sdl_save_bmp(@handle, path) != 0
    end

    # Drains events and updates the key table. True if closing was requested.
    def pump
      Sdl.sp_sdl_pump(@handle) != 0
    end

    # Plays `gamekeydown[code]`. **Returns the Integer 0/1** (by the port's conventions
    # the caller tests it with `!= 0`).
    def key(code)
      Sdl.sp_sdl_key(@handle, code)
    end

    # Microseconds since opening. **This is the only place that reads a clock**
    # (nowhere else in `lib/doom/` reads the time).
    # Milliseconds (`SDL_GetTicks`) cannot measure the distribution of 1.2 ms frames,
    # so `SDL_GetPerformanceCounter` is used.
    def elapsed_us
      Sdl.sp_sdl_us(@handle)
    end

    def delay_ms(ms)
      Sdl.sp_sdl_delay(ms)
    end

    def close
      Sdl.sp_sdl_close(@handle)
    end
  end
end
