# tests/core-blocks/src/ok.rb -- decision 0041 stage 1 on the status lane.
#
# One entry per form. run.sh compiles each with spinel-core-kernel under a
# contract it writes (a, b scalar i64; buf an inout i32 buffer counted by
# n_buf), links them with a C driver and compares what they return with
# expect.txt, which was written by hand from Ruby's rules.

def bl_times(a, b, buf, n_buf)
  s = 0
  a.times { |i| s += i }
  s
end

# The digits show the order: 1.upto(3) gives 123.
def bl_upto(a, b, buf, n_buf)
  s = 0
  a.upto(b) { |j| s = s * 10 + j }
  s
end

def bl_downto(a, b, buf, n_buf)
  s = 0
  a.downto(b) do |j|
    s = s * 10 + j
  end
  s
end

def bl_upto_count(a, b, buf, n_buf)
  c = 0
  a.upto(b) { |j| c += 1 }
  c
end

def bl_downto_count(a, b, buf, n_buf)
  c = 0
  a.downto(b) { |j| c += 1 }
  c
end

def bl_each(a, b, buf, n_buf)
  s = 0
  buf.each { |x| s += x }
  s
end

def bl_each_with_index(a, b, buf, n_buf)
  s = 0
  buf.each_with_index { |x, k| s += x * k }
  s
end

def bl_write(a, b, buf, n_buf)
  buf.each_with_index { |x, k| buf[k] = x + a }
  0
end

def bl_next(a, b, buf, n_buf)
  s = 0
  a.times do |i|
    next if i == 1
    s += i
  end
  s
end

def bl_break(a, b, buf, n_buf)
  s = 0
  a.times do |i|
    break if i == 2
    s += i
  end
  s
end

def bl_return(a, b, buf, n_buf)
  a.times { |i| return i * 10 if i == 2 }
  -1
end

def bl_nested(a, b, buf, n_buf)
  s = 0
  a.times { |i| b.times { |j| s += i * j } }
  s
end

# Assigning the receiver in the block does not change the count: it was
# read once, and the counter is hidden. (Assigning the block parameter is not
# here: when the pinned Spinel renames it, the contract reader refuses the
# file with dangling-reference; docs/decisions/0041-results.md.)
def bl_hidden(a, b, buf, n_buf)
  c = 0
  a.times do |i|
    c += 1
    a = 0
  end
  c
end

# A block's own local starts afresh each iteration, and is assigned first.
def bl_local(a, b, buf, n_buf)
  s = 0
  a.times do |i|
    t = i * 2
    s += t
  end
  s
end

def bl_overflow(a, b, buf, n_buf)
  s = 0
  a.upto(b) { |j| s += j }
  s
end

def bl_bounds(a, b, buf, n_buf)
  s = 0
  a.times { |i| s += buf[i] }
  s
end

# An exit on every iteration (the review of stage 1): nothing reaches
# the step that counts the loop on, so it is not generated.
def bl_return_all(a, b, buf, n_buf)
  a.times { |i| return 9 }
  -1
end

def bl_break_all(a, b, buf, n_buf)
  a.times { |i| break }
  7
end

def bl_return_upto(a, b, buf, n_buf)
  a.upto(b) { |i| return i }
  -1
end
