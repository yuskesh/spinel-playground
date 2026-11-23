# spinel: int64
# Decision 0022 §3: a count the body never reads, in an int64 body. A 32-bit
# target refuses the declaration (decision 0019, revised 2026-10-21);
# wrapper32.rb checks that.
def unread_u8_64(src, n_src)
  7
end
