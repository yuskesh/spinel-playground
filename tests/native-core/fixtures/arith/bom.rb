def calculate(a)
  core_w32_add(a, 1)
end

puts calculate(7)
# Decision 0042 stage 4 (tests/native-core/arith.sh): a UTF-8 byte order
# mark before the first line, which is code. The prelude goes after the
# mark in both copies (the reader's and hosted.rb).
