# tests/fs-helper-buffers/k.rb -- decision 0044: a freestanding helper indexes
# a buffer its caller lent it. Compiled for every freestanding profile; the
# drivers beside it give the entries buffers and print what comes back.
require_relative "spinel/freestanding"

# A plain helper: stores v into b[i].
def put(b, i, v)
  b[i] = v
  0
end

freestanding_def :fill_all, params: [[:f32_buf, :inout], :len], returns: :i32
def fill_all(out, n)
  i = 0
  while i < n
    put(out, i, i * 0.5)
    i += 1
  end
  n
end

# A helper that lends its lent buffer on to another helper.
def inner(b, i)
  b[i] = i * i
  0
end

def outer(b, n)
  i = 0
  while i < n
    inner(b, i)
    i += 1
  end
  n
end

freestanding_def :lend_on, params: [[:i32_buf, :inout], :len], returns: :i32
def lend_on(out, n)
  outer(out, n)
end

# One helper reached with two buffers, each with its own length.
def bump(buf, i)
  buf[i] = buf[i] + 1
  buf[i]
end

freestanding_def :two, params: [[:i32_buf, :inout], :len, [:i32_buf, :inout], :len],
                       returns: :i32
def two(a, na, b, nb)
  s = 0
  i = 0
  while i < na
    s += bump(a, i)
    i += 1
  end
  j = 0
  while j < nb
    s += bump(b, j)
    j += 1
  end
  s
end

freestanding_def :past, params: [[:i32_buf, :inout], :len, [:i32_buf, :inout], :len,
                                 :i32, :i32], returns: :i32
def past(a, na, b, nb, i, j)
  bump(a, i) + bump(b, j)
end

# A helper that reads through a buffer lent from an :in buffer.
def get(b, i)
  b[i]
end

freestanding_def :sum_in, params: [[:i32_buf, :in], :len], returns: :i32
def sum_in(src, n)
  s = 0
  i = 0
  while i < n
    s += get(src, i)
    i += 1
  end
  s
end

# A helper that walks one lent buffer with each_with_index (decision 0041)
# and stores into another.
def walk(s, d)
  s.each_with_index do |v, i|
    d[i] = v + i
  end
  0
end

freestanding_def :each_lent, params: [[:i32_buf, :in], [:i32_buf, :out], :len],
                             returns: :i32
def each_lent(src, dst, n)
  walk(src, dst)
  n
end

# A callee that is an entry too: the call goes past its wrapper, so the
# length it passes for `buf` must not exceed the length held for `out`.
freestanding_def :setk, params: [[:i32_buf, :inout], :len, :i32], returns: :i32
def setk(buf, n, i)
  buf[i] = 5
  i
end

freestanding_def :via_entry, params: [[:i32_buf, :inout], :len, :i32], returns: :i32
def via_entry(out, n, extra)
  setk(out, n + extra, 0)
end

# U1: `uput` is reached only from an unchecked entry and has no range check;
# `mput` is reached from a checked entry too, and checks.
def uput(b, i)
  b[i] = 7
  0
end

def mput(b, i)
  b[i] = 8
  0
end

freestanding_def :unchecked_put, params: [[:i32_buf, :inout], :len, :i32], returns: :i32,
                                 bounds: :unchecked
def unchecked_put(out, n, i)
  uput(out, i)
  mput(out, i)
end

freestanding_def :checked_put, params: [[:i32_buf, :inout], :len, :i32], returns: :i32
def checked_put(out, n, i)
  mput(out, i)
end

# Review finding 1: every mode that reaches a parameter counts. `wr` only
# writes, and is lent an :out and an :inout buffer; `rd` only reads, and is
# lent an :in and an :inout buffer.
def wr(b, i)
  b[i] = 4
  0
end

def rd(b, i)
  b[i]
end

freestanding_def :modes, params: [[:i32_buf, :in], [:i32_buf, :out], [:i32_buf, :inout], :len],
                         returns: :i32
def modes(src, dst, both, n)
  wr(dst, 0)
  wr(both, 0)
  rd(src, 0) + rd(both, 0)
end

# Review finding 2: U1 through an entry callee. `leaf` is reached from the
# unchecked entry `bridge`, and through it from the checked entry `chain`,
# so it checks.
def leaf(b, i)
  b[i] = 7
  0
end

freestanding_def :bridge, params: [[:i32_buf, :inout], :len, :i32], returns: :i32,
                          bounds: :unchecked
def bridge(b, n, i)
  leaf(b, i)
end

freestanding_def :chain, params: [[:i32_buf, :inout], :len, :i32], returns: :i32
def chain(b, n, i)
  bridge(b, n, i)
end

# Found during the review fix: an entry declared `bounds: :unchecked` that a
# checked entry reaches checks its own accesses too (its C boundary is
# unchanged). `unchecked_put`, which no checked entry calls, still does not.
freestanding_def :bridge2, params: [[:i32_buf, :inout], :len, :i32], returns: :i32,
                           bounds: :unchecked
def bridge2(b, n, i)
  b[i] = 6
  i
end

freestanding_def :chain2, params: [[:i32_buf, :inout], :len, :i32], returns: :i32
def chain2(b, n, i)
  bridge2(b, n, i)
end
