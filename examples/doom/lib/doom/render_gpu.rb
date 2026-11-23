# doom/lib/doom/render_gpu.rb
#
# **The route that draws the 3D view on the GPU from Ruby.**
#
# Every earlier GPU run went through a C driver, `tools/raster/raster_run.c`, rereading
# the Job IR that `dump_jobs` wrote to files. So "**a Ruby program draws DOOM on the
# GPU**" had never happened
# even once. This file is that first time.
#
# **Spinel-specific, in the same position as `video.rb`**: CRuby has no `ffi_func`.
#   So programs that keep the CRuby differential (`sim_demo.rb` / `record_demo.rb`) do
#   not require this (a port convention). Drawing itself (`render.rb` /
#   `executor.rb`) does not depend on it either: with `job_mode = 4`, `Renderer`
#   **only queues jobs**, and the caller draws.
#
# **The CPU executor is the permanent right answer** (a pillar of this work). If this route
#   fails to draw (no device / the `.vmfb` cannot be read / no table row covers K),
#   **`Renderer#draw_jobs_cpu` draws the same frame**. The GPU touched only
#   device-side buffers and **the screen has not moved by one byte** (the C side's
#   `sp_rg_frame` makes every refusal before the readback), so
#   the fallback is not a repair but **that frame's right answer**.
#
# The interface is designed like the IREE and SDL ones:
# **POD arguments + failure as the return value + the message fetched afterwards**. The one
# difference is that the job banks pass as `:int_array`: the 3 banks of `Doom::Jobs` are
# typed `Array<Int>` (the AoS layer), so Spinel can pass C the
# `.data` pointer as it is (vendor/spinel docs/FFI.md).
# **The Ruby side has not one repacking loop and allocates not one byte.**

require_relative "errors"
require_relative "jobs"

module Doom
  # Opening the GPU route failed (refusing a frame is a return value, not an exception).
  class GpuError < Error
  end

  # 1:1 with the declarations in `tools/raster/sp_raster_gpu.c`. **A stub TU with the same
  # spelling** (`sp_raster_gpu_stub.c`) answers "this binary was built without a GPU backend",
  # so `-gpu` falls back to the CPU instead of failing in a build without a GPU.
  module Raster
    ffi_func :sp_rg_available,      [],                                    :int
    ffi_func :sp_rg_open,           [:str, :str, :str],                    :int
    ffi_func :sp_rg_close,          [],                                    :void
    ffi_func :sp_rg_error,          [],                                    :str
    ffi_func :sp_rg_geometry,       [:int, :int, :int, :int, :int, :int],  :int
    ffi_func :sp_rg_resident,       [:str, :size_t, :str, :size_t,
                                     :str, :size_t, :str, :size_t],        :int
    # One frame = one call. The 3 banks pass **`.data` directly as `:int_array`**;
    # Zone and screen borrow their mutable storage; WAD remains read-only.
    # their lifetime is only the call (FFI.md), so the C side keeps nothing,
    # and that is why the WAD and the zone are **passed every frame** too.
    ffi_func :sp_rg_frame,          [:int_array, :size_t, :int_array, :size_t,
                                     :int_array, :size_t, :str_inout, :size_t,
                                     :str, :size_t, :str_inout, :size_t],        :int
    ffi_func :sp_rg_counter,        [:int],                                :int64
    ffi_func :sp_rg_counters_reset, [],                                    :void
  end

  # One GPU route. **It can always be constructed** (`initialize` calls no FFI), so the
  # caller does not need to hold nil: if the type wavered with and without `-gpu`,
  # Spinel's inference would widen to poly. Whether it opened is held in `live`.
  class GpuRaster
    # Indexes of `sp_rg_counter` (1:1 with the C side's enum).
    C_H2D = 0
    C_D2H = 1
    C_INVOKE = 2
    C_ALLOC = 3
    C_FREE = 4
    C_FRAMES = 5
    C_DISPATCH = 6
    C_REJECT = 7
    C_NWIN = 8
    C_NBATCH = 9
    # The K of the table row the host chose this frame (switched at run time).
    C_KOPAQUE = 11
    C_KSPAN = 12
    C_KMASKED = 13

    def initialize
      @live = 0
      @frames = 0
      @rejects = 0
      @logged = 0
      @wad = ""
      @nwad = 0
      @nscreen = 0
    end

    # 0 = not running / 1 = the device is open.
    def live
      @live
    end

    def frames
      @frames
    end

    def rejects
      @rejects
    end

    # Whether a real backend is linked into this binary (0/1).
    # 0 in a stub build: "no device" really exists as a build configuration.
    def available
      Raster.sp_rg_available
    end

    # Opens the device and uploads the resident resources. **It raises no exception on failure**:
    # "with no GPU you can play on the CPU" is a requirement, so it takes a form where the
    # caller can say so loudly in one line and carry on (a return value of 0 = success).
    def open(vmfb, device, entries, width, height, screen_w, screen_h, vwx, vwy)
      return 1 if Raster.sp_rg_available == 0
      return 1 if Raster.sp_rg_open(vmfb, device, entries) != 0
      if Raster.sp_rg_geometry(width, height, screen_w, screen_h, vwx, vwy) != 0
        Raster.sp_rg_close
        return 1
      end
      @nscreen = screen_w * screen_h
      @live = 1
      0
    end

    # The resident resources (atlas / flats / colormap / fuzzoffset), and the WAD whose
    # pointer alone is passed every frame. **The atlas is only a reordering of `texdata`**,
    # so sending it is the same as sending the WAD's textures.
    def resident(atlas, flatatlas, colormap, fuzzoff, waddata)
      return 1 if @live == 0
      rc = Raster.sp_rg_resident(atlas, atlas.bytesize, flatatlas, flatatlas.bytesize,
                                 colormap, colormap.bytesize, fuzzoff, fuzzoff.bytesize)
      return 1 if rc != 0
      @wad = waddata
      @nwad = waddata.bytesize
      0
    end

    # One synchronous native frame call. The FFI boundary roots and validates
    # mutable String handles; this is hosted code, not a runtime-free core entry.
    # Zero means drawn; a C rejection happens before framebuffer readback.
    def frame(jobs, scr)
      Raster.sp_rg_frame(jobs.wall_bank, jobs.nwall,
                         jobs.span_bank, jobs.nspan,
                         jobs.masked_bank, jobs.nmasked,
                         jobs.zonebuf, jobs.nzone * Jobs::ZONE_STRIDE,
                         @wad, @nwad, scr, @nscreen)
    end

    # Draws one frame. 0 = the GPU drew it / 1 = the caller should draw it with the CPU executor.
    #
    # **The loud log appears only once.** In configurations where refusals go on every frame
    # (a demo over K, a build without a backend), writing 10 996 lines is noise,
    # not loudness, and it would bring allocation into the frame loop.
    def draw(jobs, scr)
      if @live == 0
        # If not open, **the GPU did not draw this frame either**. Count it:
        # "frames=0 rejects=0" could be read as "the GPU drew 0 frames".
        @rejects += 1
        return 1
      end
      rc = frame(jobs, scr)
      if rc != 0
        @rejects += 1
        if @logged == 0
          @logged = 1
          $stderr.puts "doom: GPU raster REJECT, falling back to the CPU job " \
                       "executor for this frame (and reporting once): " \
                       "#{Raster.sp_rg_error}"
        end
        return 1
      end
      # The str_inout boundary republishes String caches after native writes.
      @frames += 1
      0
    end

    def counter(i)
      Raster.sp_rg_counter(i)
    end

    def counters_reset
      Raster.sp_rg_counters_reset
    end

    def close
      Raster.sp_rg_close if @live != 0
      @live = 0
    end

    def error
      Raster.sp_rg_error
    end
  end
end
