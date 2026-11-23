# E077 kernel file -- P003 Phase 2 (data and ABI).
#
# The same KERNEL WORLD E040 introduced -- `freestanding_def` declarations plus
# the methods they name, no top-level program, never linked into a Spinel binary
# -- with the boundary widened from "integer scalars" to "integer scalars,
# floats, and buffers the caller owns".
#
#   spinel-mlirgen e077_kern.rb --freestanding --profile <profile>.yaml -o kern.o
#
# The HOST oracle (e077_host.rb) is generated from THIS file by mkcases.py,
# which strips the declaration lines and appends a driver, so the method bodies
# on both sides are byte-identical by construction (rewrite.diff records the
# delta).  On the host the buffers are ordinary Ruby Arrays; on the four
# freestanding targets they are addresses.  Nothing in the bodies below knows
# which -- that is the point of the experiment.
#
# ---------------------------------------------------------------------------
# THE SPELLING, in one place
#
#   params: [[:u8_buf, :in], :len]     a buffer and its length: TWO entries,
#                                      TWO C parameters, TWO Ruby parameters
#   direction  :in | :out | :inout     enforced at COMPILE time (a write to an
#                                      :in buffer does not build)
#   :len                               sizes the run of buffers before it, and
#                                      is what the bounds check compares against
#   bounds:    :trap (default) | :unchecked
#   :f32 :f64                          scalars; the body computes in f64 (D-4)
#   :f32_buf :f64_buf                  float elements
#
# There is no struct.  See the E077 decision record: a struct at the boundary
# is spelled as a buffer plus an offset convention, because C ABI struct
# passing is per-target law that belongs to the backend (P003 principle 10) and
# because P003 Phase 8's flattening rule wants the boundary to be POD-flat.
# `recsum` below IS that convention, exercised on purpose.
require_relative "spinel/freestanding"

# ---- A. bytes in, one number out ------------------------------------------
# The shape E067's Honest boundary asked for out loud: instead of five calls
# per sample, hand the whole audit log across once.  Adler-32 because it is
# defined by two running sums mod 65521 -- no bit operations, which the
# freestanding subset does not have (E066 s5.2 made the same choice).
freestanding_def :adler32, params: [[:u8_buf, :in], :len], returns: :i32
def adler32(src, n)
  a = 1
  b = 0
  i = 0
  while i < n
    a = (a + src[i]) % 65521
    b = (b + a) % 65521
    i += 1
  end
  b * 65536 + a
end

# ---- B. a buffer in, a buffer out ------------------------------------------
# Boxcar moving average with a trailing window, floor division (which is what
# makes the four targets agree -- E067 s"副産物" found the same thing: the
# load-bearing semantics is Ruby's floored `/`, not the width of the integer).
freestanding_def :movavg, params: [[:i32_buf, :in], [:i32_buf, :out], :len, :i32],
                 returns: :i32
def movavg(src, dst, n, w)
  i = 0
  while i < n
    s = 0
    j = 0
    while j < w
      k = i - j
      if k < 0
        k = 0
      end
      s = s + src[k]
      j += 1
    end
    dst[i] = s / w
    i += 1
  end
  n
end

# ---- C. an :inout buffer ---------------------------------------------------
# The one direction that reads AND writes.  Also the one that shows the
# direction is not decoration: change `:inout` to `:in` and the build fails on
# the store, change it to `:out` and it fails on the load.
freestanding_def :bump, params: [[:i32_buf, :inout], :len, :i32], returns: :i32
def bump(a, n, d)
  i = 0
  while i < n
    a[i] = a[i] + d
    i += 1
  end
  n
end

# ---- D. narrowing at the ELEMENT, not at the return ------------------------
# Storing into a `:u8_buf` asks the same question a `returns: :u8` asks, and
# gets the same answer (P003 D-2 reused): under `trap` a value that does not fit
# is trap code 3.  `clamp8` never overflows; `pack8` is the same store without
# the clamp, and exists so the fault has somewhere to happen.
freestanding_def :clamp8, params: [[:i32_buf, :in], [:u8_buf, :out], :len], returns: :i32
def clamp8(src, dst, n)
  i = 0
  while i < n
    v = src[i]
    if v < 0
      v = 0
    end
    if v > 255
      v = 255
    end
    dst[i] = v
    i += 1
  end
  n
end

freestanding_def :pack8, params: [[:i32_buf, :in], [:u8_buf, :out], :len], returns: :i32
def pack8(src, dst, n)
  i = 0
  while i < n
    dst[i] = src[i]
    i += 1
  end
  n
end

# ---- E. the struct-shaped boundary, done with offsets ----------------------
# Three i32 fields per record: {id, weight, flags}.  This is the whole of the
# "struct v1" decision -- a record is a STRIDE and a set of OFFSETS, the
# arithmetic that finds a field is ordinary Ruby, and the bounds check covers
# it for free because the index it produces is an index like any other.  `n` is
# the ELEMENT count (what `:len` always means), so the record loop steps by the
# stride and stops with a whole record left.
freestanding_def :recsum, params: [[:i32_buf, :in], :len, :i32], returns: :i32
def recsum(rec, n, f)
  s = 0
  i = 0
  while i + 2 < n
    s = s + rec[i + f]
    i += 3
  end
  s
end

# ---- F. floats: a scalar boundary (R013 asked for exactly this) ------------
freestanding_def :fpoly, params: [:f32], returns: :f32
def fpoly(x)
  x * x * 0.5 + x * 0.25 - 1.0
end

freestanding_def :fmix, params: [:f32, :f64], returns: :f64
def fmix(x, y)
  x * 2.0 + y
end

# ---- G. floats: buffers ----------------------------------------------------
# f64 elements are exactly Ruby's Float, so the host oracle and the four
# targets agree bit for bit.  f32 elements round on the way in and on the way
# out (D-4), which is why the f32 cases below use dyadic values -- and why
# ONE of them deliberately does not (see expect.tsv's `diverge` row).
freestanding_def :fmean, params: [[:f64_buf, :in], :len], returns: :f64
def fmean(a, n)
  s = 0.0
  i = 0
  while i < n
    s = s + a[i]
    i += 1
  end
  s / n
end

freestanding_def :fscale, params: [[:f32_buf, :in], [:f32_buf, :out], :len, :f32],
                 returns: :i32
def fscale(src, dst, n, k)
  i = 0
  while i < n
    dst[i] = src[i] * k
    i += 1
  end
  n
end

# ---- H. `bounds: :unchecked` (E077 decision record D-5) --------------------
# The same sum with the per-index check declared away.  The entry-side checks
# (NULL buffer, negative length) stay: those are about the CALL, not the index.
freestanding_def :sum_unchecked, params: [[:i32_buf, :in], :len], returns: :i32,
                 bounds: :unchecked
def sum_unchecked(a, n)
  s = 0
  i = 0
  while i < n
    s = s + a[i]
    i += 1
  end
  s
end

# The bug the per-index check exists for: an off-by-one that reads ONE past the
# declared end.  Note what it is NOT: `adler32(src, 9)` on a five-byte buffer is
# a CALLER error and this check cannot see it (the kernel stayed inside the
# length it was given).  The check's claim is exactly "the kernel indexes within
# the length it was told", and the two failures are different sentences.
freestanding_def :sum_offby1, params: [[:i32_buf, :in], :len], returns: :i32
def sum_offby1(a, n)
  s = 0
  i = 0
  while i <= n
    s = s + a[i]
    i += 1
  end
  s
end

# The checked twin, so that "the check is what costs" is a measurement and not
# an assertion (size.tsv).
freestanding_def :sum_checked, params: [[:i32_buf, :in], :len], returns: :i32
def sum_checked(a, n)
  s = 0
  i = 0
  while i < n
    s = s + a[i]
    i += 1
  end
  s
end

# ---- I. the R012 loop, as Ruby ---------------------------------------------
# `fill` and `verify` are the two halves of the 40-line C driver R012 s7.2
# needed to close the WebGPU ring; `sumsq` is the per-element kernel the WGSL
# implements.  With buffer boundaries the C disappears: the caller-owned region
# is chosen by the JS host out of `__heap_base`, so nothing has to allocate a
# static array or hand its address back.  See r012/.
freestanding_def :fill, params: [[:i32_buf, :out], :len, :i32], returns: :i32
def fill(dst, n, n0)
  i = 0
  while i < n
    dst[i] = n0 + i
    i += 1
  end
  n
end

freestanding_def :verify, params: [[:i32_buf, :in], [:i32_buf, :in], :len], returns: :i32
def verify(inp, gpu, n)
  nd = 0
  i = 0
  while i < n
    if sumsq(inp[i]) != gpu[i]
      nd = nd + 1
    end
    i += 1
  end
  nd
end

# A private callee reached from `verify` -- the same closure rule E040 checked
# with `igcd`, now with a buffer-carrying caller.
def sumsq(n)
  s = 0
  i = 1
  while i <= n
    s = s + i * i
    i = i + 1
  end
  s
end

freestanding_def :one_sumsq, params: [:i32], returns: :i32
def one_sumsq(n)
  sumsq(n)
end

# ---- J. the contract version ----------------------------------------------
freestanding_def :ver, params: [], returns: :u16, export: :spinel_e077_version
def ver
  77
end
