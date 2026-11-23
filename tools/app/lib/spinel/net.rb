# tools/app/lib/spinel/net.rb -- byte serialisation for CORE applications.
#
# Decision 0014: an application writes its messages into a `u8` buffer with
# these helpers before handing the buffer to a channel. They are admitted CORE
# Ruby: every loop has a derived bound, nothing allocates, and every store is
# range-checked by the kernel (a byte is masked before it is stored, so no
# store can fail on its value; a position past the buffer's end is a BOUNDS
# failure of the entry, established by the compiler, not by this code).
#
# Each helper takes the buffer and a position, and returns the position after
# what it wrote. Multi-byte integers are little-endian.

def put_u8(out, pos, v)
  out[pos] = v & 0xff
  pos + 1
end

def put_u16(out, pos, v)
  out[pos] = v & 0xff
  out[pos + 1] = (v >> 8) & 0xff
  pos + 2
end

def put_i32(out, pos, v)
  out[pos] = v & 0xff
  out[pos + 1] = (v >> 8) & 0xff
  out[pos + 2] = (v >> 16) & 0xff
  out[pos + 3] = (v >> 24) & 0xff
  pos + 4
end

# Decimal ASCII. A 64-bit magnitude has at most 20 digits, so both loops are
# bounded at 20 and leave early; the sign is written first. Negating the most
# negative value is an ARITHMETIC failure of the entry, as it is everywhere.
def put_dec(out, pos, v)
  if v < 0
    out[pos] = 45
    pos += 1
    v = -v
  end
  digits = 1
  t = v
  i = 0
  while i < 20
    break if t < 10
    t = t / 10
    digits += 1
    i += 1
  end
  i = 0
  while i < 20
    break if i >= digits
    out[pos + digits - 1 - i] = 48 + v % 10
    v = v / 10
    i += 1
  end
  pos + digits
end

# The bytes of `s`, `n_s` of them. Task 5 of the 0014 plan admits a string
# literal here; until then the caller passes a buffer and its count.
def put_str(out, pos, s, n_s)
  i = 0
  while i < n_s
    out[pos + i] = s[i]
    i += 1
  end
  pos + n_s
end
