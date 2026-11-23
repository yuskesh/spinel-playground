# doom/lib/doom/hires.rb
#
# **The one tool of high-resolution mode that "stretches what was drawn at 320 onto the real
# screen".**
#
# Why it is needed. High-resolution mode made only the 3D view resolution-variable:
# `Doom::Renderer` is fully general in `@sw`/`@sh`, and walls, planes and sprites
# **really** draw 1920x1008 (the BSP runs at that resolution).
# The **status bar and HUD, though, are 320-wide patches themselves**:
#
#   * `STBAR` is one 320x32 picture, and the positions of the numbers, face and keys on it
#     are set by **40 pixel-coordinate constants** in `st_stuff.c`
#   * `StatusBar`'s redraw is an incremental update with `V_CopyRect`, resting on the
#     **pixel equivalence** "paste again from a 320x32 back buffer"
#
# Rewriting that for any resolution would abandon "copy vanilla's shape as it is", and
# would remake the whole surface the 131 gates protect. So it was solved **the other
# way round**: the status bar and HUD are **drawn as before into a 320x200 shadow buffer,
# not one byte changed**, and only their rectangle is copied to the real screen at an
# integer multiple. `Doom::StatusBar` and `Doom::Hud` have **not changed by one line**.
#
# It is nearest-neighbour at an integer multiple, so
#
#   * at s = 1, `blit_scale` is **just a rectangle copy** (it is not even called)
#   * enlarging makes no information (vanilla's picture comes out s times as it is)
#   * it meets the 3D view (`viewheight = 168*s` lines) vertically with no gap,
#     because the status bar's height becomes `32*s` lines
#
# **The 3D view passes through here not by one pixel.** Only the bottom `32*s` lines do,
# outside what the GPU / CPU executor must match bit for bit (the view rectangle).

require_relative "errors"

module Doom
  module Hires
    # Copies the rectangle (`sx`,`sy`,`w`,`h`) of the shadow buffer `src` (width `srcw`),
    # scaled by `s`, to (`sx*s`,`sy*s`) on the real screen `dst` (width `dstw`), nearest-neighbour.
    #
    # **Zero allocation** (the caller owns both buffers). It is called from the frame loop
    # every tic, so the inside is written with `getbyte`/`setbyte` only.
    def self.blit_scale(dst, dstw, src, srcw, sx, sy, w, h, s)
      raise LevelError, "blit_scale: scale #{s} must be >= 1" if s < 1
      row = 0
      while row < h
        srow = (sy + row) * srcw + sx
        ry = 0
        while ry < s
          drow = ((sy + row) * s + ry) * dstw + sx * s
          col = 0
          while col < w
            v = src.getbyte(srow + col)
            rx = 0
            d = drow + col * s
            while rx < s
              dst.setbyte(d + rx, v)
              rx += 1
            end
            col += 1
          end
          ry += 1
        end
        row += 1
      end
    end
  end
end
