# tests/core-bitwise/status/src/words.rb -- decision 0042 stage 4 on the
# status lane: one kernel per method, built by run.sh from a contract that
# declares both parameters at the body width. Each takes (a, n), so that one
# driver calls them all; a comparison answers 1 or 0. The `w64` and `u64`
# kernels are built at 64 bits only.

def w_w32_add(a, n)
  core_w32_add(a, n)
end

def w_w32_sub(a, n)
  core_w32_sub(a, n)
end

def w_w32_mul(a, n)
  core_w32_mul(a, n)
end

def w_w32_neg(a, n)
  core_w32_neg(a)
end

def w_w32_shl(a, n)
  core_w32_shl(a, n)
end

def w_u32_lt(a, n)
  core_u32_lt(a, n) ? 1 : 0
end

def w_u32_le(a, n)
  core_u32_le(a, n) ? 1 : 0
end

def w_u32_gt(a, n)
  core_u32_gt(a, n) ? 1 : 0
end

def w_u32_ge(a, n)
  core_u32_ge(a, n) ? 1 : 0
end

def w_u32_shr(a, n)
  core_u32_shr(a, n)
end

def w_fixed_mul(a, n)
  core_fixed_mul(a, n)
end

def w_fixed_div(a, n)
  core_fixed_div(a, n)
end

def w_w64_add(a, n)
  core_w64_add(a, n)
end

def w_w64_sub(a, n)
  core_w64_sub(a, n)
end

def w_w64_mul(a, n)
  core_w64_mul(a, n)
end

def w_w64_neg(a, n)
  core_w64_neg(a)
end

def w_w64_shl(a, n)
  core_w64_shl(a, n)
end

def w_u64_lt(a, n)
  core_u64_lt(a, n) ? 1 : 0
end

def w_u64_le(a, n)
  core_u64_le(a, n) ? 1 : 0
end

def w_u64_gt(a, n)
  core_u64_gt(a, n) ? 1 : 0
end

def w_u64_ge(a, n)
  core_u64_ge(a, n) ? 1 : 0
end

def w_u64_shr(a, n)
  core_u64_shr(a, n)
end

def w_u32lit(a, n)
  core_u32(0xdeadbeef)
end

# The checksum steps; the driver iterates them over the bytes.
def fnv32_seed(a, n)
  core_u32(0x811c9dc5)
end

def fnv32_step(a, n)
  core_w32_mul(a ^ n, 16777619)
end

def fnv64_step(a, n)
  core_w64_mul(a ^ n, 1099511628211)
end

def crc32_step(a, n)
  poly = core_u32(0xedb88320)
  x = a ^ n
  i = 0
  while i < 8
    x = core_u32_shr(x, 1) ^ (core_w32_neg(x & 1) & poly)
    i += 1
  end
  x
end
