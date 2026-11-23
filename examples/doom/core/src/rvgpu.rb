# spinel: int64
# examples/doom/core/src/rvgpu.rb — the CPU executor's run when the GPU refuses a frame.
#
# GPL-derived, from `examples/doom/lib/doom/render.rb`
# (`Doom::Renderer#draw_jobs_cpu`). See ../NOTICE.md and ../sources.tsv.
#
# bin/doom.rb calls Renderer#draw_jobs_cpu only under -gpu, which renders in
# job mode 4; the native program renders in job mode 0 (decision 0008,
# 2026-10-21), and doom_core_render does not call it. It is a unit of its own so that
# the three entries' packing (../entries/units.tsv) can leave it out: an
# uncalled definition that calls into an entry's closure is refused by the
# kernel. Whether the GPU refusal gets an entry of its own is the owner's to
# decide. The build-only render entry compiles it.

# `Renderer#draw_jobs_cpu`: the GPU path's refusal, drawn by the executor
def dc_rv_draw_jobs_cpu(width, height, exec_atlas_size, exec_flat_size, state, rx, wall, span, masked, xcount, xyl,
                        xyh, ycount, yx1, yx2, mcount, mlo, mhi, mseq, mfz, scr, cmap, atlas, flat, wad, zonebuf,
                        fuzzoffset, sc_kind, sc_idx, exec_width, exec_centery, exec_vwx, exec_vwy)
  dc_rv_run_jobs(width, height, exec_atlas_size, exec_flat_size, state, rx, wall, span, masked, xcount, xyl, xyh,
                 ycount, yx1, yx2, mcount, mlo, mhi, mseq, mfz, scr, cmap, atlas, flat, wad, zonebuf, fuzzoffset,
                 sc_kind, sc_idx, exec_width, exec_centery, exec_vwx, exec_vwy, 0)
  0
end
