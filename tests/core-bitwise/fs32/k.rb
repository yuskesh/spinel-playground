# tests/core-bitwise/fs32/k.rb -- decision 0042 stages 1 to 3 on the freestanding
# route at a 32-bit body width. run.sh compiles it for the wasm32 profile,
# links it with wasm-ld, runs it under node with fs32/run.mjs and compares
# what it prints with fs32/expect.txt, which was written by hand.
require_relative "spinel/freestanding"

freestanding_def :band, params: [:i32, :i32], returns: :i32
def band(a, b)
  a & b
end

freestanding_def :bor, params: [:i32, :i32], returns: :i32
def bor(a, b)
  a | b
end

freestanding_def :bxor, params: [:i32, :i32], returns: :i32
def bxor(a, b)
  a ^ b
end

freestanding_def :bnot, params: [:i32], returns: :i32
def bnot(a)
  ~a
end

freestanding_def :field, params: [:i32], returns: :i32
def field(r)
  (r & 0xf0) / 16 * 100 + (r & 0xf)
end

freestanding_def :set_clear, params: [:i32], returns: :i32
def set_clear(r)
  (r | 0x80) & ~0x01
end

# 0xffff_ffff does not fit a 32-bit Integer; the largest mask that does.
freestanding_def :mask31, params: [:i32], returns: :i32
def mask31(a)
  a & 0x7fff_ffff
end

freestanding_def :op_write, params: [:i32], returns: :i32
def op_write(a)
  x = a
  x &= 0xff
  x |= 0x100
  x ^= 1
  x
end

# Decision 0042 stage 2: the shifts, under `trap` (the default) and `wrap`.
# run.sh feeds them the rows of shifts.tsv.
freestanding_def :shl, params: [:i32, :i32], returns: :i32
def shl(a, n)
  a << n
end

freestanding_def :shr, params: [:i32, :i32], returns: :i32
def shr(a, n)
  a >> n
end

freestanding_def :shl_w, params: [:i32, :i32], returns: :i32, overflow: :wrap
def shl_w(a, n)
  a << n
end

freestanding_def :shr_w, params: [:i32, :i32], returns: :i32, overflow: :wrap
def shr_w(a, n)
  a >> n
end

freestanding_def :opw_shift, params: [:i32], returns: :i32
def opw_shift(a)
  x = a
  x <<= 4
  x >>= 2
  x
end

# Decision 0042 stage 3: `abs` and `**`, under `trap` and `wrap`. run.sh
# feeds them the rows of powers.tsv. Every one takes (a, n), so that one
# driver calls them all; `ab` and the constant powers `pkE` ignore n.
freestanding_def :ab, params: [:i32, :i32], returns: :i32
def ab(a, n)
  a.abs
end

freestanding_def :ab_w, params: [:i32, :i32], returns: :i32, overflow: :wrap
def ab_w(a, n)
  a.abs
end

freestanding_def :pw, params: [:i32, :i32], returns: :i32
def pw(a, n)
  a ** n
end

freestanding_def :pw_w, params: [:i32, :i32], returns: :i32, overflow: :wrap
def pw_w(a, n)
  a ** n
end

freestanding_def :pk0, params: [:i32, :i32], returns: :i32
def pk0(a, n)
  a ** 0
end

freestanding_def :pk0_w, params: [:i32, :i32], returns: :i32, overflow: :wrap
def pk0_w(a, n)
  a ** 0
end

freestanding_def :pk1, params: [:i32, :i32], returns: :i32
def pk1(a, n)
  a ** 1
end

freestanding_def :pk1_w, params: [:i32, :i32], returns: :i32, overflow: :wrap
def pk1_w(a, n)
  a ** 1
end

freestanding_def :pk2, params: [:i32, :i32], returns: :i32
def pk2(a, n)
  a ** 2
end

freestanding_def :pk2_w, params: [:i32, :i32], returns: :i32, overflow: :wrap
def pk2_w(a, n)
  a ** 2
end

freestanding_def :pk31, params: [:i32, :i32], returns: :i32
def pk31(a, n)
  a ** 31
end

freestanding_def :pk31_w, params: [:i32, :i32], returns: :i32, overflow: :wrap
def pk31_w(a, n)
  a ** 31
end

freestanding_def :pk63, params: [:i32, :i32], returns: :i32
def pk63(a, n)
  a ** 63
end

freestanding_def :pk63_w, params: [:i32, :i32], returns: :i32, overflow: :wrap
def pk63_w(a, n)
  a ** 63
end

freestanding_def :opw_pow, params: [:i32], returns: :i32
def opw_pow(a)
  x = a
  x **= 3
  x
end

# Decision 0042 stage 4: one function per intrinsic, each taking (a, b),
# so that one driver calls them all. run.sh feeds them the 32-bit rows of
# words.tsv; `w_u32lit` is `core_u32(0xdeadbeef)`. A comparison answers 1 or 0.
freestanding_def :w_w32_add, params: [:i32, :i32], returns: :i32
def w_w32_add(a, b)
  core_w32_add(a, b)
end

freestanding_def :w_w32_sub, params: [:i32, :i32], returns: :i32
def w_w32_sub(a, b)
  core_w32_sub(a, b)
end

freestanding_def :w_w32_mul, params: [:i32, :i32], returns: :i32
def w_w32_mul(a, b)
  core_w32_mul(a, b)
end

freestanding_def :w_w32_neg, params: [:i32, :i32], returns: :i32
def w_w32_neg(a, b)
  core_w32_neg(a)
end

freestanding_def :w_w32_shl, params: [:i32, :i32], returns: :i32
def w_w32_shl(a, b)
  core_w32_shl(a, b)
end

freestanding_def :w_u32_lt, params: [:i32, :i32], returns: :i32
def w_u32_lt(a, b)
  core_u32_lt(a, b) ? 1 : 0
end

freestanding_def :w_u32_le, params: [:i32, :i32], returns: :i32
def w_u32_le(a, b)
  core_u32_le(a, b) ? 1 : 0
end

freestanding_def :w_u32_gt, params: [:i32, :i32], returns: :i32
def w_u32_gt(a, b)
  core_u32_gt(a, b) ? 1 : 0
end

freestanding_def :w_u32_ge, params: [:i32, :i32], returns: :i32
def w_u32_ge(a, b)
  core_u32_ge(a, b) ? 1 : 0
end

freestanding_def :w_u32_shr, params: [:i32, :i32], returns: :i32
def w_u32_shr(a, b)
  core_u32_shr(a, b)
end

freestanding_def :w_fixed_mul, params: [:i32, :i32], returns: :i32
def w_fixed_mul(a, b)
  core_fixed_mul(a, b)
end

freestanding_def :w_fixed_div, params: [:i32, :i32], returns: :i32
def w_fixed_div(a, b)
  core_fixed_div(a, b)
end

freestanding_def :w_u32lit, params: [:i32, :i32], returns: :i32
def w_u32lit(a, b)
  core_u32(0xdeadbeef)
end

# The checksum steps; the driver iterates them over the bytes of the
# published check strings. FNV-1a: xor the byte in, then multiply by the prime.
freestanding_def :fnv32_seed, params: [], returns: :i32
def fnv32_seed
  core_u32(0x811c9dc5)
end

freestanding_def :fnv32_step, params: [:i32, :i32], returns: :i32
def fnv32_step(h, b)
  core_w32_mul(h ^ b, 16777619)
end

# One byte of the reflected CRC-32 (polynomial 0xedb88320).
freestanding_def :crc32_step, params: [:i32, :i32], returns: :i32
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
