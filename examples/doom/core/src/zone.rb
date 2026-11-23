# examples/doom/core/src/zone.rb — the zone windows a masked column reads past its lump.
#
# GPL-derived, from `examples/doom/lib/doom/wad.rb` (`Doom::Wad#zone_window_into`,
# `#zone_header_byte`) and `examples/doom/lib/doom/jobs.rb`
# (`Doom::Jobs#alloc_zone_window`, `#reset`), which reproduce doomgeneric's `z_zone.c` block
# layout as `r_draw.c`'s 127-masked read sees it, and reset the job banks'
# per-frame counters. See ../NOTICE.md and ../sources.tsv.
#
# A MASKED POST NEAR THE END OF ITS LUMP IS READ 128 BYTES AT A TIME, and the bytes
# past the lump are what the reference's zone allocator put there: padding to 8,
# a 40-byte `memblock_t` describing the next block, then the next lump in
# directory order. `dc_zone_window_into` writes those 128 bytes into `out` at
# `base`. Where they go is the caller's: the direct path's single window at 0,
# or the job ring at the slot `dc_alloc_zone_window` hands out -- and the ring is
# ONE store, the one the executor reads (docs/core/doom-source-alias.md, C).
#
# The lump directory arrives as the resident fields Full prepares -- each
# entry's position and size, and the next lump the zone would hold -- rather
# than as the original's Lump objects.

ZONE_HEADER = 40
ZONE_TAG_CACHE = 8
ZONE_ID = 0x1d4a11
ZONE_STRIDE = 128

# Byte `k` of the `memblock_t` after lump `ln`, which describes the NEXT block.
# The user, next and prev fields are pointers the reference cannot reproduce;
# they are 0, as the original has them.
def dc_zone_header_byte(lump_size, next_lump, ln, k)
  nx = next_lump[ln]
  return 0 if nx < 0
  if k < 4
    sz = (((lump_size[nx] + 7) >> 3) << 3) + ZONE_HEADER
    (sz >> (k << 3)) & 0xff
  elsif k >= 16 && k < 20
    k == 16 ? ZONE_TAG_CACHE : 0
  elsif k >= 20 && k < 24
    (ZONE_ID >> ((k - 20) << 3)) & 0xff
  else
    0
  end
end

# The 128 bytes from `off` in lump `lumpnum`, as the zone holds them, into `out`
# at `base`.
def dc_zone_window_into(wad, lump_pos, lump_size, next_lump, out, lumpnum, off, base)
  ln = lumpnum
  a = off
  i = 0
  while i < 128
    size = lump_size[ln]
    if a < size
      out[base + i] = wad[lump_pos[ln] + a]
      i += 1
      a += 1
    else
      j = a - size
      pad = (((size + 7) >> 3) << 3) - size
      if j < pad + ZONE_HEADER
        b = 0
        if j >= pad
          b = dc_zone_header_byte(lump_size, next_lump, ln, j - pad)
        end
        out[base + i] = b
        i += 1
        a += 1
      else
        nx = next_lump[ln]
        if nx < 0
          out[base + i] = 0
          i += 1
          a += 1
        else
          ln = nx
          a = j - pad - ZONE_HEADER
        end
      end
    end
  end
  0
end

# One ring slot for a queued job's window: the offset into the ring, a multiple
# of 128. A full ring is CAPACITY, as the original's `JobError` is. The counter
# is a scalar field of `core_state`, named by its slot index; the ring's slot
# count is a value Full prepares, a buffer of its own.
def dc_alloc_zone_window(state, i_nzone, zone_slots)
  i = state[i_nzone]
  if i >= zone_slots[0]
    core_fail(:capacity)
  end
  state[i_nzone] = i + 1
  i * ZONE_STRIDE
end

# `Jobs#reset`, at the start of every frame the jobs are gathered for: the
# per-frame counters back to 0 -- the ring's `nzone` among them, which is what
# lets the next frame's windows start at slot 0 -- and `fuzz_suffix` to 1. The
# counters are scalar fields of `core_state`; `zero_slots` holds the slot index
# of each one reset to 0, and `i_fuzz_suffix` the one reset to 1. The running
# totals the original keeps are not reset, and are not in the table.
def dc_jobs_reset(state, zero_slots, n_zero_slots, i_fuzz_suffix)
  k = 0
  while k < n_zero_slots
    state[zero_slots[k]] = 0
    k += 1
  end
  state[i_fuzz_suffix] = 1
  0
end
