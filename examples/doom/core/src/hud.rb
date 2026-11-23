# examples/doom/core/src/hud.rb — the HUD's message line.
#
# GPL-derived, from `examples/doom/lib/doom/hud.rb` (`Doom::Hud#draw` and
# `#draw_patch`), which reproduce doomgeneric's `hu_lib.c` (`HUlib_drawTextLine`)
# and `v_video.c` (`V_DrawPatch`). See ../NOTICE.md and ../sources.tsv.
#
# THIS IS WHY THE RECORDED ORACLE STOPPED AT FRAME 59. The message line is drawn
# at y = 0, INSIDE the 3D view, and the recording was taken from a route that
# draws it. Until the port drew it too, every frame after the first message --
# DEMO1's is at frame 60 -- differed from the recording in the view itself.
#
# IT IS ITS OWN CLOSURE, SO IT CARRIES ITS OWN COPIES OF THE BYTE READERS. An
# entry's selected closure must be disjoint from every other entry's -- the
# kernel refuses a call into one closure from outside it -- and dc_i16 and dc_i32
# already belong to the status bar's. The rule is to duplicate a helper that
# separate operations USE and merge only definitions that are ONE operation; the
# HUD is not part of drawing the bar. So dc_hud_i16 and dc_hud_i32 are copies,
# and tests/doom-core/dup-check.rb holds them identical to the originals modulo
# the name.
#
# dc_hud_draw_patch IS NOT A COPY OF dc_draw_patch. The HUD's patch walk clips
# each pixel vertically against the screen and never refuses; the status bar's
# refuses a patch that would fall outside its destination. Two routines, not one
# routine twice.
#
# THE MESSAGES ARE ONE BYTE BUFFER. `text` (hud_texts) holds every message end
# to end, and `text_ofs` (hud_text_ofs) where each starts, with one more entry
# for where the last ends: message m is the bytes from text_ofs[m] to
# text_ofs[m + 1]. No length table is kept beside it -- a second list of the same
# fact could disagree with the first. Both are `resource` fields in
# examples/doom/core/state.tsv, prepared by Full and only read here.

HU_SCREENHEIGHT = 200
HU_FONTSTART = 33
HU_FONTEND = 95
HU_SPACE_ADVANCE = 4
HU_LINE_WIDTH = 320
HU_POST_END = 0xff

# The HUD's copies of the status bar's readers. Identical bodies, other names.
def dc_hud_i16(buf, o)
  v = buf[o] | (buf[o + 1] << 8)
  v >= 0x8000 ? v - 0x10000 : v
end

def dc_hud_i32(buf, o)
  # the top byte placed by a word multiply: the i32 is its signed pattern at once
  buf[o] | (buf[o + 1] << 8) | (buf[o + 2] << 16) | core_w32_mul(buf[o + 3], 16777216)
end

# `V_DrawPatch` as the HUD calls it: no refusal, each pixel clipped to the
# screen's height, and every pixel written `scale` by `scale` times. Answers 0.
def dc_hud_draw_patch(dest, wad, lump_pos, sw, scale, x, y, lumpnum)
  base = lump_pos[lumpnum]
  w = dc_hud_i16(wad, base)
  dx = x - dc_hud_i16(wad, base + 4)
  dy = y - dc_hud_i16(wad, base + 6)
  col = 0
  while col < w
    p = base + dc_hud_i32(wad, base + 8 + col * 4)
    while true
      td = wad[p]
      break if td == HU_POST_END
      len = wad[p + 1]
      src = p + 3
      k = 0
      while k < len
        yy = dy + td + k
        if yy >= 0 && yy < HU_SCREENHEIGHT
          v = wad[src + k]
          ry = 0
          while ry < scale
            o = (yy * scale + ry) * sw + (dx + col) * scale
            rx = 0
            while rx < scale
              dest[o + rx] = v
              rx += 1
            end
            ry += 1
          end
        end
        k += 1
      end
      p += len + 4
    end
    col += 1
  end
  0
end

# `HUlib_drawTextLine` at the top-left, no cursor. Nothing is drawn unless a
# message is on. Lower-case letters are drawn in upper case; a character with no
# glyph advances by four pixels; the line stops at the screen's width.
#
# `message` and `message_on` are the GAME's state, written by the HUD's ticker,
# which is step work: they are cells of `state`, named by index, and reach the
# port through the boundary copy. `sw` and `scale` are one-element resources.
#
# THE LOOP STOPS THROUGH A FLAG, NOT `break`. The original breaks at the end of
# each branch, which the checker refuses as a `break` in value position and as a
# conditional with no value on one path. The flag keeps the original's two
# different stopping rules exactly: a glyph that would cross the line stops the
# line BEFORE it is drawn and leaves x where it was; a space stops it AFTER x has
# advanced past the line.
def dc_draw_hud(screen, wad, lump_pos, font_lump, text, text_ofs, sw_b, scale_b,
                state, i_message, i_message_on)
  return 0 if state[i_message_on] == 0
  message = state[i_message]
  sw = sw_b[0]
  scale = scale_b[0]
  start = text_ofs[message]
  n = text_ofs[message + 1] - start
  x = 0
  i = 0
  stop = 0
  while i < n && stop == 0
    c = text[start + i]
    i += 1
    c -= 32 if c >= 97 && c <= 122
    if c != 32 && c >= HU_FONTSTART && c <= HU_FONTEND
      lump = font_lump[c - HU_FONTSTART]
      w = dc_hud_i16(wad, lump_pos[lump])
      if x + w > HU_LINE_WIDTH
        stop = 1
      else
        dc_hud_draw_patch(screen, wad, lump_pos, sw, scale, x, 0, lump)
        x += w
      end
    else
      x += HU_SPACE_ADVANCE
      stop = x >= HU_LINE_WIDTH ? 1 : 0
    end
  end
  0
end
