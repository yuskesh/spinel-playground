# tests/core-bitwise/status/src/st_w64_32.rb -- decision 0042 stage 4: a
# 64-bit form in a kernel built at --int-width=32, refused as int64 is.

def st_w64_32(a, n)
  core_w64_add(a, n)
end
