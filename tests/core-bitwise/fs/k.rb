# tests/core-bitwise/fs/k.rb -- decision 0042 stages 1 to 3 on the freestanding
# route (spinel-fs-emit) at a 64-bit body width. run.sh compiles it for the
# x86_64 Linux host profile, links it with fs/drive.c and compares what it
# prints with fs/expect.txt, which was written by hand from Ruby's rules.
require_relative "spinel/freestanding"

freestanding_def :band, params: [:i64, :i64], returns: :i64
def band(a, b)
  a & b
end

freestanding_def :bor, params: [:i64, :i64], returns: :i64
def bor(a, b)
  a | b
end

freestanding_def :bxor, params: [:i64, :i64], returns: :i64
def bxor(a, b)
  a ^ b
end

freestanding_def :bnot, params: [:i64], returns: :i64
def bnot(a)
  ~a
end

# A register field: bits 4..7 as the hundreds, bits 0..3 as the units.
freestanding_def :field, params: [:i64], returns: :i64
def field(r)
  (r & 0xf0) / 16 * 100 + (r & 0xf)
end

# Set bit 7 and clear bit 0.
freestanding_def :set_clear, params: [:i64], returns: :i64
def set_clear(r)
  (r | 0x80) & ~0x01
end

freestanding_def :mask32, params: [:i64], returns: :i64
def mask32(a)
  a & 0xffff_ffff
end

freestanding_def :op_write, params: [:i64], returns: :i64
def op_write(a)
  x = a
  x &= 0xff
  x |= 0x100
  x ^= 1
  x
end

# Decision 0042 stage 2: the shifts, under `trap` (the default) and `wrap`.
# run.sh feeds them the rows of shifts.tsv.
freestanding_def :shl, params: [:i64, :i64], returns: :i64
def shl(a, n)
  a << n
end

freestanding_def :shr, params: [:i64, :i64], returns: :i64
def shr(a, n)
  a >> n
end

freestanding_def :shl_w, params: [:i64, :i64], returns: :i64, overflow: :wrap
def shl_w(a, n)
  a << n
end

freestanding_def :shr_w, params: [:i64, :i64], returns: :i64, overflow: :wrap
def shr_w(a, n)
  a >> n
end

freestanding_def :opw_shift, params: [:i64], returns: :i64
def opw_shift(a)
  x = a
  x <<= 4
  x >>= 2
  x
end

# Decision 0042 stage 3: `abs` and `**`, under `trap` and `wrap`. run.sh
# feeds them the rows of powers.tsv. Every one takes (a, n), so that one
# driver calls them all; `ab` and the constant powers `pkE` ignore n.
freestanding_def :ab, params: [:i64, :i64], returns: :i64
def ab(a, n)
  a.abs
end

freestanding_def :ab_w, params: [:i64, :i64], returns: :i64, overflow: :wrap
def ab_w(a, n)
  a.abs
end

freestanding_def :pw, params: [:i64, :i64], returns: :i64
def pw(a, n)
  a ** n
end

freestanding_def :pw_w, params: [:i64, :i64], returns: :i64, overflow: :wrap
def pw_w(a, n)
  a ** n
end

freestanding_def :pk0, params: [:i64, :i64], returns: :i64
def pk0(a, n)
  a ** 0
end

freestanding_def :pk0_w, params: [:i64, :i64], returns: :i64, overflow: :wrap
def pk0_w(a, n)
  a ** 0
end

freestanding_def :pk1, params: [:i64, :i64], returns: :i64
def pk1(a, n)
  a ** 1
end

freestanding_def :pk1_w, params: [:i64, :i64], returns: :i64, overflow: :wrap
def pk1_w(a, n)
  a ** 1
end

freestanding_def :pk2, params: [:i64, :i64], returns: :i64
def pk2(a, n)
  a ** 2
end

freestanding_def :pk2_w, params: [:i64, :i64], returns: :i64, overflow: :wrap
def pk2_w(a, n)
  a ** 2
end

freestanding_def :pk31, params: [:i64, :i64], returns: :i64
def pk31(a, n)
  a ** 31
end

freestanding_def :pk31_w, params: [:i64, :i64], returns: :i64, overflow: :wrap
def pk31_w(a, n)
  a ** 31
end

freestanding_def :pk63, params: [:i64, :i64], returns: :i64
def pk63(a, n)
  a ** 63
end

freestanding_def :pk63_w, params: [:i64, :i64], returns: :i64, overflow: :wrap
def pk63_w(a, n)
  a ** 63
end

freestanding_def :opw_pow, params: [:i64], returns: :i64
def opw_pow(a)
  x = a
  x **= 3
  x
end

# Decision 0042 stage 4: one function per intrinsic, each taking (a, b),
# so that one driver calls them all. run.sh feeds them the 64-bit rows of
# words.tsv; `w_u32lit` is `core_u32(0xdeadbeef)`. A comparison answers 1 or 0.
freestanding_def :w_w32_add, params: [:i64, :i64], returns: :i64
def w_w32_add(a, b)
  core_w32_add(a, b)
end

freestanding_def :w_w32_sub, params: [:i64, :i64], returns: :i64
def w_w32_sub(a, b)
  core_w32_sub(a, b)
end

freestanding_def :w_w32_mul, params: [:i64, :i64], returns: :i64
def w_w32_mul(a, b)
  core_w32_mul(a, b)
end

freestanding_def :w_w32_neg, params: [:i64, :i64], returns: :i64
def w_w32_neg(a, b)
  core_w32_neg(a)
end

freestanding_def :w_w32_shl, params: [:i64, :i64], returns: :i64
def w_w32_shl(a, b)
  core_w32_shl(a, b)
end

freestanding_def :w_u32_lt, params: [:i64, :i64], returns: :i64
def w_u32_lt(a, b)
  core_u32_lt(a, b) ? 1 : 0
end

freestanding_def :w_u32_le, params: [:i64, :i64], returns: :i64
def w_u32_le(a, b)
  core_u32_le(a, b) ? 1 : 0
end

freestanding_def :w_u32_gt, params: [:i64, :i64], returns: :i64
def w_u32_gt(a, b)
  core_u32_gt(a, b) ? 1 : 0
end

freestanding_def :w_u32_ge, params: [:i64, :i64], returns: :i64
def w_u32_ge(a, b)
  core_u32_ge(a, b) ? 1 : 0
end

freestanding_def :w_u32_shr, params: [:i64, :i64], returns: :i64
def w_u32_shr(a, b)
  core_u32_shr(a, b)
end

freestanding_def :w_fixed_mul, params: [:i64, :i64], returns: :i64
def w_fixed_mul(a, b)
  core_fixed_mul(a, b)
end

freestanding_def :w_fixed_div, params: [:i64, :i64], returns: :i64
def w_fixed_div(a, b)
  core_fixed_div(a, b)
end

freestanding_def :w_w64_add, params: [:i64, :i64], returns: :i64
def w_w64_add(a, b)
  core_w64_add(a, b)
end

freestanding_def :w_w64_sub, params: [:i64, :i64], returns: :i64
def w_w64_sub(a, b)
  core_w64_sub(a, b)
end

freestanding_def :w_w64_mul, params: [:i64, :i64], returns: :i64
def w_w64_mul(a, b)
  core_w64_mul(a, b)
end

freestanding_def :w_w64_neg, params: [:i64, :i64], returns: :i64
def w_w64_neg(a, b)
  core_w64_neg(a)
end

freestanding_def :w_w64_shl, params: [:i64, :i64], returns: :i64
def w_w64_shl(a, b)
  core_w64_shl(a, b)
end

freestanding_def :w_u64_lt, params: [:i64, :i64], returns: :i64
def w_u64_lt(a, b)
  core_u64_lt(a, b) ? 1 : 0
end

freestanding_def :w_u64_le, params: [:i64, :i64], returns: :i64
def w_u64_le(a, b)
  core_u64_le(a, b) ? 1 : 0
end

freestanding_def :w_u64_gt, params: [:i64, :i64], returns: :i64
def w_u64_gt(a, b)
  core_u64_gt(a, b) ? 1 : 0
end

freestanding_def :w_u64_ge, params: [:i64, :i64], returns: :i64
def w_u64_ge(a, b)
  core_u64_ge(a, b) ? 1 : 0
end

freestanding_def :w_u64_shr, params: [:i64, :i64], returns: :i64
def w_u64_shr(a, b)
  core_u64_shr(a, b)
end

freestanding_def :w_u32lit, params: [:i64, :i64], returns: :i64
def w_u32lit(a, b)
  core_u32(0xdeadbeef)
end

# `core_w32_add` wraps under `overflow: :wrap` too, and its operand check
# still fails.
freestanding_def :w_w32_add_w, params: [:i64, :i64], returns: :i64, overflow: :wrap
def w_w32_add_w(a, b)
  core_w32_add(a, b)
end

# The checksum steps; the driver iterates them over the bytes of the
# published check strings. FNV-1a: xor the byte in, then multiply by the prime.
freestanding_def :fnv32_seed, params: [], returns: :i64
def fnv32_seed
  core_u32(0x811c9dc5)
end

freestanding_def :fnv32_step, params: [:i64, :i64], returns: :i64
def fnv32_step(h, b)
  core_w32_mul(h ^ b, 16777619)
end

freestanding_def :fnv64_step, params: [:i64, :i64], returns: :i64
def fnv64_step(h, b)
  core_w64_mul(h ^ b, 1099511628211)
end

# One byte of the reflected CRC-32 (polynomial 0xedb88320).
freestanding_def :crc32_step, params: [:i64, :i64], returns: :i64
def crc32_step(c, b)
  poly = core_u32(0xedb88320)
  x = c ^ b
  i = 0
  while i < 8
    x = core_u32_shr(x, 1) ^ (core_w32_neg(x & 1) & poly)
    i += 1
  end
  x
end
