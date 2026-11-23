# examples/doom/core/src/planespan.rb — the plane spans a visplane's columns emit.
#
# GPL-derived, from `examples/doom/lib/doom/render.rb` (`Doom::Renderer#make_spans`,
# `#map_plane`, and the packed `position`/`step` of `#draw_span`'s job-mode
# branch), which reproduce doomgeneric's `r_plane.c` (`R_MakeSpans`,
# `R_MapPlane`) and the packed span source of `r_draw.c`'s `R_DrawSpan`. See
# ../NOTICE.md and ../sources.tsv.
#
# A VISPLANE IS WALKED COLUMN BY COLUMN. `make_spans` compares the column's top
# and bottom with the previous column's: where a run ends it emits the span from
# the x it started at to the column before this one, and where a run starts it
# records the start. What it emits is one `map_plane`, which computes the span's
# source position and step and its colormap row and pushes the job.
#
# `map_plane`'s per-row cache is the original's: the first row at a given plane
# height computes the distance and the x/y steps and keeps them; a later row at
# the same height reads them back. `Renderer#clear_planes`, which zeroes the
# cache each frame, and `#draw_planes`' per-plane body, which chooses the plane
# and sets `planeheight`, `planezlight` and `curpicnum`, are in src/planes.rb.
#
# The span push is written out here rather than calling the push unit's
# `dc_push_span`: a definition inside one entry's closure may not be called from
# outside it, and that entry has its own.
#
# Every table arrives as a borrowed buffer and every scalar field as an index
# into `core_state`. The flat atlas base is `flattranslation[curpicnum] * 4096`,
# the expression `Textures#flat_atlas_base` is, inlined here -- that accessor
# has no row of its own.

PS_SP_NF = 7
PS_KIND_SPAN = 1
PS_ANGLETOFINESHIFT = 19
PS_LIGHTZSHIFT = 20
PS_MAXLIGHTZ = 128
PS_FLAT_BYTES = 4096

# `map_plane` and the job it pushes: the span at row y from x1 to x2.
def dc_plane_span(state, cachedheight, cacheddistance, cachedxstep, cachedystep, yslope, distscale,
                  xtoviewangle, finesine, zlight, flattranslation, span, sc_kind, sc_idx, cap_span, cap_sched,
                  i_planeheight, i_basexscale, i_baseyscale, i_viewangle, i_viewx, i_viewy,
                  i_planezlight, i_curpicnum, i_nspan, i_nsched, y, x1, x2, jobmode, scr, cmap, flat, sw, viewwindowx, viewwindowy)
  ph = state[i_planeheight]
  distance = 0
  xstep = 0
  ystep = 0
  if ph != cachedheight[y]
    cachedheight[y] = ph
    distance = core_fixed_mul(ph, yslope[y])
    cacheddistance[y] = distance
    xstep = core_fixed_mul(distance, state[i_basexscale])
    ystep = core_fixed_mul(distance, state[i_baseyscale])
    cachedxstep[y] = xstep
    cachedystep[y] = ystep
  else
    distance = cacheddistance[y]
    xstep = cachedxstep[y]
    ystep = cachedystep[y]
  end
  length = core_fixed_mul(distance, distscale[x1])
  angle = core_u32_shr(core_w32_add(state[i_viewangle], xtoviewangle[x1]), PS_ANGLETOFINESHIFT)
  c = finesine[angle + 2048]
  s = finesine[angle]
  xfrac = core_w32_add(state[i_viewx], core_fixed_mul(c, length))
  yfrac = core_w32_sub(core_w32_neg(state[i_viewy]), core_fixed_mul(s, length))
  index = distance >> PS_LIGHTZSHIFT
  index = PS_MAXLIGHTZ - 1 if index >= PS_MAXLIGHTZ
  cmrow = zlight[state[i_planezlight] + index]
  # the packed span source: x in the high 16 bits, y in the low 16, bits 6..21
  # of each (C: ((xfrac << 10) & 0xffff0000) | ((yfrac >> 6) & 0xffff)), the
  # high half placed by a word multiply (decision 0022)
  position = core_w32_mul((xfrac >> 6) & 0xffff, 65536) | ((yfrac >> 6) & 0xffff)
  step = core_w32_mul((xstep >> 6) & 0xffff, 65536) | ((ystep >> 6) & 0xffff)
  if jobmode[0] == 0
    # job mode 0, Renderer#draw_span's direct path: the span drawn here, from
    # the flat atlas, by the executor's exec_span's own pixel loop
    fbase = flattranslation[state[i_curpicnum]] * PS_FLAT_BYTES
    cm = cmrow * 256
    o = (y + viewwindowy[0]) * sw[0] + x1 + viewwindowx[0]
    count = x2 - x1
    k = 0
    while k <= count
      spot = core_u32_shr(position, 26) | ((position >> 4) & 0x0fc0)
      scr[o] = cmap[cm + flat[fbase + spot]]
      o += 1
      position = core_w32_add(position, step)
      k += 1
    end
    return 0
  end
  # `push_span`, written out: the record, then the schedule entry
  i = state[i_nspan]
  if i >= cap_span[0]
    core_fail(:capacity)
  end
  b = i * PS_SP_NF
  span[b] = y
  span[b + 1] = x1
  span[b + 2] = x2
  span[b + 3] = position
  span[b + 4] = step
  span[b + 5] = flattranslation[state[i_curpicnum]] * PS_FLAT_BYTES
  span[b + 6] = cmrow
  state[i_nspan] = i + 1
  sc = state[i_nsched]
  if sc >= cap_sched[0]
    core_fail(:capacity)
  end
  sc_kind[sc] = PS_KIND_SPAN
  sc_idx[sc] = i
  state[i_nsched] = sc + 1
  0
end

# `make_spans`: this column's top and bottom against the previous column's.
def dc_make_spans(state, spanstart, cachedheight, cacheddistance, cachedxstep, cachedystep, yslope, distscale,
                  xtoviewangle, finesine, zlight, flattranslation, span, sc_kind, sc_idx, cap_span, cap_sched,
                  i_planeheight, i_basexscale, i_baseyscale, i_viewangle, i_viewx, i_viewy,
                  i_planezlight, i_curpicnum, i_nspan, i_nsched, x, t1, b1, t2, b2, jobmode, scr, cmap, flat, sw, viewwindowx, viewwindowy)
  a1 = t1
  c1 = b1
  a2 = t2
  c2 = b2
  while a1 < a2 && a1 <= c1
    dc_plane_span(state, cachedheight, cacheddistance, cachedxstep, cachedystep, yslope, distscale,
                  xtoviewangle, finesine, zlight, flattranslation, span, sc_kind, sc_idx, cap_span, cap_sched,
                  i_planeheight, i_basexscale, i_baseyscale, i_viewangle, i_viewx, i_viewy,
                  i_planezlight, i_curpicnum, i_nspan, i_nsched, a1, spanstart[a1], x - 1, jobmode, scr, cmap, flat, sw, viewwindowx, viewwindowy)
    a1 += 1
  end
  while c1 > c2 && c1 >= a1
    dc_plane_span(state, cachedheight, cacheddistance, cachedxstep, cachedystep, yslope, distscale,
                  xtoviewangle, finesine, zlight, flattranslation, span, sc_kind, sc_idx, cap_span, cap_sched,
                  i_planeheight, i_basexscale, i_baseyscale, i_viewangle, i_viewx, i_viewy,
                  i_planezlight, i_curpicnum, i_nspan, i_nsched, c1, spanstart[c1], x - 1, jobmode, scr, cmap, flat, sw, viewwindowx, viewwindowy)
    c1 -= 1
  end
  while a2 < a1 && a2 <= c2
    spanstart[a2] = x
    a2 += 1
  end
  while c2 > c1 && c2 >= a2
    spanstart[c2] = x
    c2 -= 1
  end
  0
end
