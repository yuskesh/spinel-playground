# tests/core-blocks/fs/k.rb -- decision 0041 stage 1 on the freestanding route
# (spinel-fs-emit). run.sh compiles it for the x86_64 Linux host profile, links
# it with fs/drive.c and compares what it prints with fs/expect.txt, which was
# written by hand from Ruby's rules.
require_relative "spinel/freestanding"

freestanding_def :tri, params: [:i32], returns: :i32
def tri(n)
  s = 0
  n.times do |i|
    t = i + 1
    s += t
  end
  s
end

# 1.upto(3) adds 1 + 2 + 3, then 3.downto(1) takes 2 * (3 + 2 + 1).
freestanding_def :span, params: [:i32, :i32], returns: :i32
def span(a, b)
  s = 0
  a.upto(b) { |j| s += j }
  b.downto(a) { |j| s -= 2 * j }
  s
end

freestanding_def :order, params: [:i32, :i32], returns: :i32
def order(a, b)
  s = 0
  b.downto(a) { |j| s = s * 10 + j }
  s
end

freestanding_def :sum, params: [[:i32_buf, :in], :len], returns: :i32
def sum(buf, len)
  s = 0
  buf.each { |x| s += x }
  buf.each_with_index { |x, i| s += x * i }
  s
end

# Counting to the largest i32 ends without stepping past it.
freestanding_def :edge, params: [:i32], returns: :i32
def edge(a)
  c = 0
  a.upto(2147483647) { |j| c += 1 }
  c
end

# a return on every iteration: nothing steps the counter (the review of stage 1)
freestanding_def :first, params: [:i32], returns: :i32
def first(n)
  n.times { |i| return 9 }
  -1
end

tri(3)
span(1, 3)
order(1, 3)
sum([1, 2, 3], 3)
edge(2147483645)
first(3)
