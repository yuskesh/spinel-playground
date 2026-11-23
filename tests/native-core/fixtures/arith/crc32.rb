# Decision 0042 stage 4 (tests/native-core/arith.sh): CRC-32 of "123456789"
# (0xcbf43926), a reflected byte step with the polynomial 0xedb88320, from -1
# and complemented. One bit of the step; `--core` has no loop, so the byte
# step is unrolled.
def crc32_bit(x)
  core_u32_shr(x, 1) ^ (core_w32_neg(x & 1) & core_u32(0xedb88320))
end

def crc32_step(c, b)
  x = c ^ b
  x = crc32_bit(x)
  x = crc32_bit(x)
  x = crc32_bit(x)
  x = crc32_bit(x)
  x = crc32_bit(x)
  x = crc32_bit(x)
  x = crc32_bit(x)
  x = crc32_bit(x)
  x
end

def calculate(b0, b1, b2, b3, b4, b5, b6, b7, b8)
  c = -1
  c = crc32_step(c, b0)
  c = crc32_step(c, b1)
  c = crc32_step(c, b2)
  c = crc32_step(c, b3)
  c = crc32_step(c, b4)
  c = crc32_step(c, b5)
  c = crc32_step(c, b6)
  c = crc32_step(c, b7)
  c = crc32_step(c, b8)
  ~c
end

puts calculate(49, 50, 51, 52, 53, 54, 55, 56, 57)
