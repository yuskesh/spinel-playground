# Decision 0022 §3: an i32 result, so the result pointer needs only 4-byte
# alignment and r + 4 can be 2^32.
def tag_u8(src, n_src)
  1
end
