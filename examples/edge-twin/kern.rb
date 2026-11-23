# spinel: int64
# edge-twin -- THE SHARED KERNEL.
#
# This one file is the whole of the agreement between a device and an edge
# worker.  It is compiled twice, by the same generator, from the same bytes:
#
#   spinel-mlirgen kern.rb --freestanding \
#       --profile tools/freestanding/profiles/cortex-m33-zephyr.yaml -o kern.o
#   spinel-mlirgen kern.rb --freestanding \
#       --profile tools/freestanding/profiles/wasm32-worker.yaml     -o kern.o
#
# and the claim the example exists to demonstrate is that the two answer with
# THE SAME BITS -- so an audit log a Cortex-M33 wrote can be replayed on
# Cloudflare's edge and checked digit for digit, with no reference
# implementation, no floating point and no "close enough".
#
# ---------------------------------------------------------------------------
# WHY THE STATE IS SPELLED OUT INSTEAD OF RETURNED AS A TUPLE
#
# A freestanding boundary carries ONE integer of a declared width (P003 Phase 2
# adds pointers and structs; today there are none).  A sequential filter wants
# to return `(state', mean, var)`, so the shape it takes here is: the state is
# an explicit tuple of i64 registers that the CALLER owns, and each component of
# the update is one pure entry over the whole previous state.  That is a
# restriction, and it buys something back -- every entry is a pure function of
# its arguments, so "replay" is just calling them again in the same order, and
# there is no hidden state anywhere for the two sides to disagree about.
#
# THE UPDATE ORDER IS PART OF THE CONTRACT.  For every sample x, all four calls
# read the PREVIOUS state (mean_q, var_q, hi, lo):
#
#     v     = verdict(mean_q, var_q, x, k)
#     hi'   = digest_hi(hi, lo, x, v)
#     lo'   = digest_lo(hi, lo, x, v)
#     mean' = ewma_mean(mean_q, x)
#     var'  = ewma_var(var_q, mean_q, x)
#
# Both digest halves take the OLD pair, so they can be computed in either order;
# ewma_var takes the OLD mean, so it does not matter whether the mean is updated
# first.  A driver that gets this wrong produces a different log, which is
# exactly what the differential oracle would catch.
#
# ---------------------------------------------------------------------------
# FIXED POINT, AND THE DECLARED DOMAIN
#
# There is no Float here (P003 Phase 6, and the profile says `libm: none`), so
# the filter is integer Q16: a value `u` is carried as `u * 65536`.  `/` in Ruby
# is FLOORED, which is what makes `/ 65536` and `/ 256` exactly an arithmetic
# shift and therefore exactly reproducible on every target -- including for
# negative values, where C's truncating `/` would not be.
#
# THE DOMAIN IS DECLARED, NOT ASSUMED: |x| <= 100000 and 1 <= k <= 8.  Inside
# it, nothing in this file can overflow the i64 body.  Outside it the kernel
# does not return a wrong number -- it calls the platform's trap hook and does
# not come back (P003 decision record D-2).  The example shows both sides of
# that: on the MCU the trap is `k_panic()`, on the worker it is a 422.  The
# first sample that overflows `sq16` is x = 11863284 from a zero state, and the
# demo probes 11863283 (last value that computes) next to it.
require_relative "spinel/freestanding"

# ---------------------------------------------------------------------------
# 1. the deterministic sensor
#
# A Lehmer generator mod 2^31-1 (the "minimal standard").  It is here rather
# than in the drivers so that the INPUT SEQUENCE is bit-identical on all five
# runners too -- a differential test whose two sides generate their own inputs
# is only testing the generators.
freestanding_def :prng_next, params: [:i64], returns: :i64
def prng_next(s)
  (s * 48271) % 2147483647
end

# One PRNG state -> one reading in milli-degrees.  Roughly N(25000, 866) by way
# of a uniform 3001-wide window, with a +9000 spike (about 10 sigma) whenever
# the state is divisible by 97 -- i.e. about one reading in a hundred is the
# anomaly the detector is supposed to find.
freestanding_def :sample_of, params: [:i64], returns: :i32
def sample_of(s)
  base = 25000 + (s % 3001) - 1500
  return base + 9000 if s % 97 == 0
  base
end

# The tail of the input sequence: boundary values, in the kernel so that the
# device driver, the worker and the host oracle cannot disagree about what they
# are.  All of them are inside the declared domain; the two that are not
# (11863283 / 11863284) are the trap probe and are NOT part of the stream.
freestanding_def :bound_sample, params: [:i32], returns: :i32
def bound_sample(i)
  return 0 if i == 0
  return 1 if i == 1
  return -1 if i == 2
  return 2 if i == 3
  return -2 if i == 4
  return 255 if i == 5
  return 256 if i == 6
  return -256 if i == 7
  return 32767 if i == 8
  return -32768 if i == 9
  return 32768 if i == 10
  return 46340 if i == 11
  return -46340 if i == 12
  return 46341 if i == 13
  return -46341 if i == 14
  return 65535 if i == 15
  return 65536 if i == 16
  return -65536 if i == 17
  return 99999 if i == 18
  return 100000 if i == 19
  return -100000 if i == 20
  return 25000 if i == 21
  return 24999 if i == 22
  25001
end

# ---------------------------------------------------------------------------
# 2. the sequential mean/variance filter
#
# `sq16` is NOT exported: it is a private callee shared by two entries, which is
# also the shape E040 used to check that the call-graph closure pulls a callee
# in once and that both entries agree on the overflow policy.
#
# It squares a Q16 deviation and returns a Q16 square.  Doing it as
# `(d / 256) * (d / 256)` rather than `(d * d) / 65536` is the whole reason the
# declared domain can be as wide as it is: the intermediate never exceeds
# (|d|/256)^2, so |x| up to 100000 has ~7 orders of magnitude of headroom,
# where `d * d` would overflow at |x| ~ 46341.  The rounding difference is
# deterministic and therefore identical on every target -- which is the only
# property this example needs from it.
def sq16(d)
  q = d / 256
  q * q
end

# Seed the filter from the first reading instead of from zero, so the warm-up
# transient is short and the same everywhere.
freestanding_def :seed_mean, params: [:i32], returns: :i64
def seed_mean(x)
  x * 65536
end

# EWMA with alpha = 1/16.  Floored division, so this is a shift.
freestanding_def :ewma_mean, params: [:i64, :i32], returns: :i64
def ewma_mean(mean_q, x)
  mean_q + ((x * 65536 - mean_q) / 16)
end

# The matching variance recursion, reading the PREVIOUS mean (see the header).
freestanding_def :ewma_var, params: [:i64, :i64, :i32], returns: :i64
def ewma_var(var_q, mean_q, x)
  var_q + ((sq16(x * 65536 - mean_q) - var_q) / 16)
end

# ---------------------------------------------------------------------------
# 3. the anomaly verdict
#
# 0 = normal, 1 = beyond k sigma, 2 = beyond 2k sigma.  Comparing SQUARES keeps
# the integer sqrt out of the kernel entirely.  The `+ 163840000` is a variance
# floor (sigma_min = 50 milli-degrees, in Q16), without which a perfectly quiet
# sensor would report every ripple as an anomaly.
#
# Level 2 asks `s > 4 * t` but is written `s / 4 > t`, because `4 * t` is the
# one product in this file that could leave the i64 body at the top of the
# declared domain.  The floored `/ 4` is exact for the purposes of a threshold
# and, again, identical on every target.
freestanding_def :verdict, params: [:i64, :i64, :i32, :i32], returns: :i32
def verdict(mean_q, var_q, x, k)
  s = sq16(x * 65536 - mean_q)
  t = k * k * (var_q + 163840000)
  return 2 if s / 4 > t
  return 1 if s > t
  0
end

# ---------------------------------------------------------------------------
# 4. the audit chain
#
# THIS IS NOT A CRYPTOGRAPHIC HASH and the example never claims it is: it is a
# 62-bit rolling checksum over (sample, verdict) in two 31-bit halves, and an
# adversary who knows these six constants can forge a log.  What it does buy is
# what an audit needs first: a single pair of numbers at the end of a run that
# no accidental edit -- a changed reading, a flipped verdict, a dropped or
# reordered row -- can survive, and that the edge can recompute from the log
# alone.  Replacing it with a real MAC is a kernel change and nothing else,
# because everything around it only ever sees (hi, lo).
#
# Both halves are mod 2^31-1, so a digest always fits :i32 and the pair is
# printable as two plain integers on a serial line.
freestanding_def :digest_hi, params: [:i32, :i32, :i32, :i32], returns: :i32
def digest_hi(hi, lo, x, v)
  (hi * 1000003 + lo + x * 7 + v * 131) % 2147483647
end

freestanding_def :digest_lo, params: [:i32, :i32, :i32, :i32], returns: :i32
def digest_lo(hi, lo, x, v)
  (lo * 16777619 + hi + x * 31 + v * 17) % 2147483647
end

# ---------------------------------------------------------------------------
# 5. the contract version
#
# The audit log carries this number and the edge refuses to replay a log that
# was not produced by the same kernel.  A twin whose halves can silently drift
# apart is worse than no twin at all, so the version is part of the boundary and
# not part of a comment.
freestanding_def :kern_version, params: [], returns: :u16
def kern_version
  67
end
