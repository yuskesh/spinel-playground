# spinel: int64
# examples/gatekeeper/kern.rb -- THE GATEKEEPER KERNEL (freestanding subset).
#
# This file is never run and never linked into a Spinel binary.  It is compiled
# by
#
#   tools/mlir/spinel-mlirgen kern.rb --freestanding \
#       --profile tools/freestanding/profiles/wasm32-worker.yaml -o kern.o
#
# into a ~2 KB wasm module whose ONLY import is `env.spinel_trap` -- no GC, no
# allocator, no wasi, no libc (E063).  Every request the worker sees goes
# through these functions before anything else happens, so what they are
# allowed to cost, and what they are allowed to depend on, is the whole design.
#
# ---- WHY THESE THREE JOBS LIVE HERE AND NOT IN app.rb ----------------------
#
# P003 Phase 8's placement rule draws the line at ALLOCATION AND DETERMINISM,
# not at speed:
#
#   * a decision that must come out the same on every PoP (an A/B bucket, a
#     rate verdict) cannot be allowed to depend on a heap, a hash seed, a
#     float, or a library version;
#   * a decision that runs before authentication runs on every request,
#     including the ones you are trying to shed, so it must not be able to
#     start a runtime.
#
# The practical litmus test P003 states is: CAN EVERYTHING THAT CROSSES THE
# BOUNDARY BE FLATTENED INTO PLAIN OLD DATA?  For all three jobs below the
# answer is yes, and the flattening is the interesting part:
#
#   token bucket   the STATE (level, last-seen timestamp) stays on the JS side
#                  in KV / a Durable Object / a Map.  The kernel is a pure
#                  function of six i64s.  Nothing here remembers anything.
#   bucketing      the key arrives already hashed, as two i64 halves.  Hashing
#                  a *string* would need a string, and a string needs a heap.
#   bot score      the features (header count, UA length, inter-arrival gap...)
#                  are extracted by the router, which already has the parsed
#                  Request, and arrive as a vector of i32.
#
# ---- THE ANSWER SET --------------------------------------------------------
#
# A kernel function has exactly two ways to answer: a value, or a trap.  Which
# one is used where is a deliberate contract:
#
#   TRAP  is reserved for ARITHMETIC FACTS -- an overflow, a zero divisor, a
#         value that does not fit the declared boundary.  Those are exactly the
#         things the generator can detect, and they mean the DEPLOYMENT is
#         broken (a rate of zero, a corrupted timestamp), not that a client
#         sent something odd.  The router turns a trap into 422 and the isolate
#         lives on (E063 §7).
#   VALUE, including the -1 sentinel on the bucketing entries, is used for
#         domain checks.  The router validates client-shaped input before it
#         gets here; -1 is defence in depth, not the primary check.
#
# The one thing that must NOT happen is a SILENT wrap.  Measured on these same
# bytes with `overflow: wrap` (E066 §5): a corrupted timestamp makes the refill
# come back 0, so the identity is locked out for good and nothing says so.
# Every declaration below therefore keeps the profile's `overflow: trap`.
#
# ---- THE SUBSET ------------------------------------------------------------
#
# Integers only, and only + - * / % and comparisons (no bit operations, no
# constants, no arrays, no strings).  So all mixing below is MODULAR ARITHMETIC
# mod 2**31-1, chosen so that every intermediate product stays under 2**62 and
# therefore CANNOT overflow i64.  That is what makes the native Spinel build of
# these same method bodies -- where Integer is arbitrary precision -- print the
# same characters as the wasm module: there is no overflow for the two to
# disagree about.  (`reject_*.rb` next door show what the subset refuses.)

require_relative "spinel/freestanding"

# --------------------------------------------------------------------------
# 1. TOKEN BUCKET -- the state belongs to the caller
# --------------------------------------------------------------------------
# Tokens are counted in MILLI-TOKENS (mt) so that a fractional refill rate
# needs no float: 1000 mt = 1 request's worth.
#
#   prev_mt     tokens the caller last wrote down            (mt)
#   prev_ts     when it wrote them down                      (ms, epoch)
#   now_ts      now                                          (ms, epoch)
#   rate_mt_s   refill rate                                  (mt per second)
#   burst_mt    cap                                          (mt)
#   cost_mt     what this request costs                      (mt)
#
# `tb_level` is private (no freestanding_def): it is reached from all three
# entries below and the generator pulls it in once.

def tb_level(prev_mt, prev_ts, now_ts, rate_mt_s, burst_mt)
  el = now_ts - prev_ts
  # Clock skew or stale state must never ADD debt: a negative elapsed time is
  # read as "no time passed", never as "take tokens away".
  el = 0 if el < 0
  # A corrupted prev_ts (or a rate somebody typed with six extra zeros) makes
  # this product overflow -- and that is trap code 1, deliberately.  Wrapping
  # here answers with a number nobody chose, quietly (E066 §5).
  add = el * rate_mt_s / 1000
  lvl = prev_mt + add
  lvl = burst_mt if lvl > burst_mt
  lvl = 0 if lvl < 0
  lvl
end

# 1 = serve it, 0 = shed it.  A byte, because that is what a decision is.
freestanding_def :tb_allow, params: [:i64, :i64, :i64, :i64, :i64, :i64], returns: :u8
def tb_allow(prev_mt, prev_ts, now_ts, rate_mt_s, burst_mt, cost_mt)
  return 1 if tb_level(prev_mt, prev_ts, now_ts, rate_mt_s, burst_mt) >= cost_mt
  0
end

# The level to write back.  Called with the SAME six arguments as tb_allow, so
# the two answers are consistent by construction -- the alternative would be a
# struct return, and the freestanding boundary has no struct (P003 Phase 2).
# Two calls of a pure function is the honest flattening; a packed i64 carrying
# both would be a private encoding nobody else could read.
freestanding_def :tb_tokens, params: [:i64, :i64, :i64, :i64, :i64, :i64], returns: :i64
def tb_tokens(prev_mt, prev_ts, now_ts, rate_mt_s, burst_mt, cost_mt)
  lvl = tb_level(prev_mt, prev_ts, now_ts, rate_mt_s, burst_mt)
  return lvl - cost_mt if lvl >= cost_mt
  lvl
end

# Seconds until the request would be affordable -- the Retry-After header.
# :u16 because that is the range a Retry-After worth sending has, and it is the
# boundary that says so: a wait longer than 65535 s does not fit and traps
# (code 3) rather than arriving truncated.  A rate of 0 traps too (code 2):
# a bucket that never refills has no honest retry time.
freestanding_def :tb_retry_after, params: [:i64, :i64, :i64, :i64, :i64, :i64], returns: :u16
def tb_retry_after(prev_mt, prev_ts, now_ts, rate_mt_s, burst_mt, cost_mt)
  lvl = tb_level(prev_mt, prev_ts, now_ts, rate_mt_s, burst_mt)
  return 0 if lvl >= cost_mt
  need = cost_mt - lvl
  (need + rate_mt_s - 1) / rate_mt_s
end

# --------------------------------------------------------------------------
# 2. BUCKETING -- the same key must land in the same bucket on every PoP
# --------------------------------------------------------------------------
# The key arrives as two i64 halves of a hash the router already computed
# (FNV-1a over the identity string, on the JS side, where strings live).
#
# `mix_step` mixes one lane into a running state in the field mod 2**31-1.
# Both operands are reduced first, so the widest intermediate is
#
#     (2**31-2)**2  <  2**62
#
# which cannot overflow i64.  No overflow means no trap and no wrap, which is
# why native Ruby (arbitrary precision) and wasm (fixed i64) agree bit for bit.
#
# THE TWO SQUARINGS ARE NOT DECORATION.  An affine step alone (a*A+C mod P) is
# a bijection but a LINEAR one, and rendezvous hashing takes an argmax over
# mix(key, 0..n-1) -- so with a linear step the weights for consecutive i are
# an arithmetic progression and the argmax lands on the same few buckets over
# and over.  Measured, with the affine step alone: the worst bucket was 245.3%
# off its share at n=8.  Squaring is the cheapest nonlinearity available in a
# subset that has no bit operations, and two rounds bring the same measurement
# to 1.35% (docs/experiments/results/E066/stability.tsv).

def mix_step(h, x)
  a = (h + x % 2147483647) % 2147483647
  b = (a * a + 1013904223) % 2147483647
  c = (b * b + 1442695041) % 2147483647
  (c * 1103515245 + 12345) % 2147483647
end

def hrw_weight(hi, lo, i)
  h = mix_step(1013904223, hi)
  h = mix_step(h, lo)
  mix_step(h, i)
end

# RENDEZVOUS (highest random weight) bucketing.  O(n) in the bucket count, and
# n is a handful, so the loop is the cheap part.  The property that earns the
# loop: changing n moves only ~1/n of the keys, where plain modulo moves almost
# all of them.  Ties go to the lower index (strict >), so the answer does not
# depend on iteration order beyond what is written here.
freestanding_def :bucket_hrw, params: [:i64, :i64, :i32], returns: :i32
def bucket_hrw(hi, lo, n)
  return -1 if n < 1
  return -1 if n > 4096
  best = 0
  bestw = -1
  i = 0
  while i < n
    w = hrw_weight(hi, lo, i)
    if w > bestw
      bestw = w
      best = i
    end
    i += 1
  end
  best
end

# The naive alternative, kept so the experiment can MEASURE the difference
# rather than assert it.  Same mixing, one modulo.
freestanding_def :bucket_mod, params: [:i64, :i64, :i32], returns: :i32
def bucket_mod(hi, lo, n)
  return -1 if n < 1
  return -1 if n > 4096
  h = mix_step(1013904223, hi)
  h = mix_step(h, lo)
  h % n
end

# --------------------------------------------------------------------------
# 3. BOT SCORE -- integer features in, 0..100 out
# --------------------------------------------------------------------------
# The router extracts the features because it is the side that has a parsed
# Request; the kernel only weighs them.  Weights are integers and the sum is
# clamped, so the score is a :u8 that cannot trap.  Nothing here is clever --
# the point is that it is the same arithmetic everywhere, forever.
#
#   hdr_count    number of request headers
#   ua_len       bytes of User-Agent (0 when absent)
#   gap_ms       ms since this identity's previous request (-1 when unknown)
#   path_len     bytes of the URL path
#   query_len    bytes of the query string
#   method_post  1 for a body-bearing method, 0 otherwise
freestanding_def :bot_score, params: [:i32, :i32, :i32, :i32, :i32, :i32], returns: :u8
def bot_score(hdr_count, ua_len, gap_ms, path_len, query_len, method_post)
  s = 0
  s += 25 if hdr_count < 4
  s += 15 if hdr_count > 40
  s += 30 if ua_len == 0
  s += 20 if ua_len > 0 && ua_len < 12
  s += 10 if ua_len > 400
  s += 25 if gap_ms >= 0 && gap_ms < 120
  s += 10 if gap_ms >= 120 && gap_ms < 400
  s += 10 if path_len > 120
  s += 15 if query_len > 512
  s += 5 if method_post == 1
  s = 100 if s > 100
  s
end

# The verdict, with the threshold passed in so that tuning it is a deployment
# change and not a recompile.  Reaches bot_score as a second entry into the
# same body -- the closure is pulled in once, and both entries agree on the
# overflow policy by construction.
freestanding_def :bot_block, params: [:i32, :i32, :i32, :i32, :i32, :i32, :i32], returns: :u8
def bot_block(hdr_count, ua_len, gap_ms, path_len, query_len, method_post, threshold)
  return 1 if bot_score(hdr_count, ua_len, gap_ms, path_len, query_len, method_post) >= threshold
  0
end

# --------------------------------------------------------------------------
# 4. VERSION -- no parameters, unsigned boundary, renamed export
# --------------------------------------------------------------------------
# The router refuses to start if this does not match what it was built against:
# the kernel and the router are deployed as one artifact, and a mismatch means
# somebody shipped half of it.
freestanding_def :gate_version, params: [], returns: :u16, export: :spinel_gate_abi_version
def gate_version
  1
end
