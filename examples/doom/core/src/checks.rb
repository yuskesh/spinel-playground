# examples/doom/core/src/checks.rb — the job banks' per-frame interval tables and statistics.
#
# GPL-derived, from `examples/doom/lib/doom/jobs.rb` (`Doom::Jobs#check_disjoint`,
# `#check_span_disjoint`, `#check_masked_k`, `#check_wall_all`), which measure,
# frame by frame, how the columns and spans doomgeneric's `r_segs.c`,
# `r_plane.c` and `r_things.c` issue stack up per screen column or row. See
# ../NOTICE.md and ../sources.tsv.
#
# EACH CHECK BUILDS ITS TABLE AND COUNTS. For every screen column (or row) it
# records the y (or x) interval of each non-empty job there, and it keeps the
# largest number of jobs one column holds and how many pairs of them overlap.
# A column holding more jobs than its table has slots is CAPACITY, where the
# original raises `JobError`; the slots filled before it stay.
#
# ONLY THE PATH THE ORIGINAL TAKES WITH `strict` FALSE IS HERE -- the one job
# mode 2 runs. With `strict` the original also raises when a column holds more
# than K_MAX jobs or two of them overlap; no status says that, so those raises
# are not ported. Neither is `Jobs#check`, which calls these after its own
# per-job checks: it stays Full's.
#
# The counters are scalar fields of `core_state`, named by their slot indices;
# the banks and the tables are borrowed buffers; the screen's width and height
# are values Full prepares, one-element buffers of their own. Each check is
# written out whole: a helper two of them shared would be reached from outside
# each entry's closure, which the kernel tool refuses.

CK_WC_NF = 7
CK_SP_NF = 7
CK_MC_NF = 9
CK_K_CAP = 64
CK_SPAN_K_CAP = 256
CK_MASKED_K_CAP = 256

# `check_disjoint(lo, hi)`: the wall jobs lo...hi (phase 0) per x -- `max_k`
# and `overlaps`.
def dc_check_disjoint(state, wall, xcount, xyl, xyh, width, lo, i_hi, i_max_k, i_overlaps)
  w = width[0]
  x = 0
  while x < w
    xcount[x] = 0
    x += 1
  end
  hi = state[i_hi]
  i = lo
  while i < hi
    b = i * CK_WC_NF
    yl = wall[b + 1]
    yh = wall[b + 2]
    if yl <= yh
      x = wall[b]
      k = xcount[x]
      if k >= CK_K_CAP
        core_fail(:capacity)
      end
      xyl[x * CK_K_CAP + k] = yl
      xyh[x * CK_K_CAP + k] = yh
      xcount[x] = k + 1
    end
    i += 1
  end
  x = 0
  while x < w
    k = xcount[x]
    state[i_max_k] = k if k > state[i_max_k]
    a = 0
    while a < k
      bb = a + 1
      while bb < k
        al = xyl[x * CK_K_CAP + a]
        ah = xyh[x * CK_K_CAP + a]
        bl = xyl[x * CK_K_CAP + bb]
        bh = xyh[x * CK_K_CAP + bb]
        if al <= bh && bl <= ah
          state[i_overlaps] = state[i_overlaps] + 1
        end
        bb += 1
      end
      a += 1
    end
    x += 1
  end
  0
end

# `check_span_disjoint`: every span per y -- `span_max_kx` and `span_overlaps`.
def dc_check_span_disjoint(state, span, ycount, yx1, yx2, height, i_nspan, i_span_max_kx, i_span_overlaps)
  h = height[0]
  y = 0
  while y < h
    ycount[y] = 0
    y += 1
  end
  n = state[i_nspan]
  i = 0
  while i < n
    b = i * CK_SP_NF
    x1 = span[b + 1]
    x2 = span[b + 2]
    if x1 <= x2
      yy = span[b]
      k = ycount[yy]
      if k >= CK_SPAN_K_CAP
        core_fail(:capacity)
      end
      yx1[yy * CK_SPAN_K_CAP + k] = x1
      yx2[yy * CK_SPAN_K_CAP + k] = x2
      ycount[yy] = k + 1
    end
    i += 1
  end
  y = 0
  while y < h
    k = ycount[y]
    state[i_span_max_kx] = k if k > state[i_span_max_kx]
    a = 0
    while a < k
      bb = a + 1
      while bb < k
        al = yx1[y * CK_SPAN_K_CAP + a]
        ah = yx2[y * CK_SPAN_K_CAP + a]
        bl = yx1[y * CK_SPAN_K_CAP + bb]
        bh = yx2[y * CK_SPAN_K_CAP + bb]
        if al <= bh && bl <= ah
          state[i_span_overlaps] = state[i_span_overlaps] + 1
        end
        bb += 1
      end
      a += 1
    end
    y += 1
  end
  0
end

# `check_masked_k`: every masked job per x, fuzz columns apart -- `fuzz_n`,
# `masked_max_kx` and `fuzz_max_kx`. Masked jobs may overlap; nothing counts that.
def dc_check_masked_k(state, masked, mcount, mlo, mhi, mseq, mfz, width,
                      i_nmasked, i_fuzz_n, i_masked_max_kx, i_fuzz_max_kx)
  w = width[0]
  x = 0
  while x < w
    mcount[x] = 0
    x += 1
  end
  nf = 0
  n = state[i_nmasked]
  i = 0
  while i < n
    b = i * CK_MC_NF
    yl = masked[b + 1]
    yh = masked[b + 2]
    if yl <= yh
      x = masked[b]
      k = mcount[x]
      if k >= CK_MASKED_K_CAP
        core_fail(:capacity)
      end
      mlo[x * CK_MASKED_K_CAP + k] = yl
      mhi[x * CK_MASKED_K_CAP + k] = yh
      mseq[x * CK_MASKED_K_CAP + k] = i
      mfz[x * CK_MASKED_K_CAP + k] = masked[b + 8]
      mcount[x] = k + 1
      nf += 1 if masked[b + 8] >= 0
    end
    i += 1
  end
  state[i_fuzz_n] = nf
  x = 0
  while x < w
    k = mcount[x]
    kf = 0
    km = 0
    a = 0
    while a < k
      if mfz[x * CK_MASKED_K_CAP + a] >= 0
        kf += 1
      else
        km += 1
      end
      a += 1
    end
    state[i_masked_max_kx] = km if km > state[i_masked_max_kx]
    state[i_fuzz_max_kx] = kf if kf > state[i_fuzz_max_kx]
    x += 1
  end
  0
end

# `check_wall_all`: the whole wall bank per x, sky included -- `wall_all_max_k`
# and `wall_all_overlaps`, over the same x tables `check_disjoint` fills.
def dc_check_wall_all(state, wall, xcount, xyl, xyh, width, i_nwall, i_wall_all_max_k, i_wall_all_overlaps)
  w = width[0]
  x = 0
  while x < w
    xcount[x] = 0
    x += 1
  end
  n = state[i_nwall]
  i = 0
  while i < n
    b = i * CK_WC_NF
    yl = wall[b + 1]
    yh = wall[b + 2]
    if yl <= yh
      x = wall[b]
      k = xcount[x]
      if k >= CK_K_CAP
        core_fail(:capacity)
      end
      xyl[x * CK_K_CAP + k] = yl
      xyh[x * CK_K_CAP + k] = yh
      xcount[x] = k + 1
    end
    i += 1
  end
  x = 0
  while x < w
    k = xcount[x]
    state[i_wall_all_max_k] = k if k > state[i_wall_all_max_k]
    a = 0
    while a < k
      bb = a + 1
      while bb < k
        al = xyl[x * CK_K_CAP + a]
        ah = xyh[x * CK_K_CAP + a]
        bl = xyl[x * CK_K_CAP + bb]
        bh = xyh[x * CK_K_CAP + bb]
        if al <= bh && bl <= ah
          state[i_wall_all_overlaps] = state[i_wall_all_overlaps] + 1
        end
        bb += 1
      end
      a += 1
    end
    x += 1
  end
  0
end
