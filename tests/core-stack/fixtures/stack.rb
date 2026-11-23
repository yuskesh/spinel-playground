# tests/core-stack/fixtures/stack.rb -- decision 0010 step 2 stack fixtures.
#
# Two of 0010's proof-of-concept acceptance items are "a deliberately large
# frame and a deep acyclic call chain are reported correctly". Both are
# properties of THE FINAL IR, not of this source: the frame sizes and the call
# graph are read after optimisation and inlining, so a chain the inliner
# flattens is one frame and proves nothing about depth.
#
# Each level therefore carries enough live state and enough work that the
# inliner declines it, and the test asserts the SHAPE it actually got -- the
# number of frames on the worst path -- rather than assuming the source shape
# survived. If a later compiler inlines these after all, the assertion fails
# and says so, which is the point: it is measuring the artifact.
#
# The contract convention is tests/core-report/contracts.rb's: `cnt` is an
# inout i64 buffer counted by `n_cnt` and every other parameter an i64 scalar.

# ---- a deep acyclic call chain ---------------------------------------------
#
# Eight levels, each with its own loop and its own live values, and each
# calling exactly one level below it. Nothing calls upwards, so the graph is
# acyclic and the worst path is the whole chain.

def st_d8(cnt, a, b)
  s = a
  i = 0
  while i < 4
    s = s + b + i
    cnt[0] += 1
    i += 1
  end
  s
end

def st_d7(cnt, a, b)
  s = st_d8(cnt, a, b)
  s = s + st_d8(cnt, b, a)
  t = a - b
  i = 0
  while i < 4
    s = s + t + i
    t = t + s
    cnt[1] += 1
    i += 1
  end
  s + t
end

def st_d6(cnt, a, b)
  s = st_d7(cnt, a, b)
  s = s + st_d7(cnt, b, a)
  t = a * 3 - b
  u = b * 5 + a
  i = 0
  while i < 4
    s = s + t + u
    t = t + s
    u = u - t
    cnt[2] += 1
    i += 1
  end
  s + t + u
end

def st_d5(cnt, a, b)
  s = st_d6(cnt, a, b)
  s = s + st_d6(cnt, b, a)
  t = a * 7 - b
  u = b * 11 + a
  v = a + b + 13
  i = 0
  while i < 4
    s = s + t + u + v
    t = t + s
    u = u - t
    v = v + u
    cnt[3] += 1
    i += 1
  end
  s + t + u + v
end

def st_d4(cnt, a, b)
  s = st_d5(cnt, a, b)
  s = s + st_d5(cnt, b, a)
  t = a * 17 - b
  u = b * 19 + a
  v = a + b + 23
  w = a - b - 29
  i = 0
  while i < 4
    s = s + t + u + v + w
    t = t + s
    u = u - t
    v = v + u
    w = w - v
    cnt[4] += 1
    i += 1
  end
  s + t + u + v + w
end

def st_d3(cnt, a, b)
  s = st_d4(cnt, a, b)
  s = s + st_d4(cnt, b, a)
  t = a * 31 - b
  u = b * 37 + a
  v = a + b + 41
  w = a - b - 43
  x = a * b + 47
  i = 0
  while i < 4
    s = s + t + u + v + w + x
    t = t + s
    u = u - t
    v = v + u
    w = w - v
    x = x + w
    cnt[5] += 1
    i += 1
  end
  s + t + u + v + w + x
end

def st_d2(cnt, a, b)
  s = st_d3(cnt, a, b)
  s = s + st_d3(cnt, b, a)
  t = a * 53 - b
  u = b * 59 + a
  v = a + b + 61
  w = a - b - 67
  x = a * b + 71
  y = a + b * 73
  i = 0
  while i < 4
    s = s + t + u + v + w + x + y
    t = t + s
    u = u - t
    v = v + u
    w = w - v
    x = x + w
    y = y - x
    cnt[6] += 1
    i += 1
  end
  s + t + u + v + w + x + y
end

def st_deep(cnt, n_cnt, a, b)
  s = st_d2(cnt, a, b)
  s = s + st_d2(cnt, b, a)
  t = a * 79 - b
  u = b * 83 + a
  v = a + b + 89
  w = a - b - 97
  x = a * b + 101
  y = a + b * 103
  z = a - b * 107
  i = 0
  while i < 4
    s = s + t + u + v + w + x + y + z
    t = t + s
    u = u - t
    v = v + u
    w = w - v
    x = x + w
    y = y - x
    z = z + y
    cnt[7] += 1
    i += 1
  end
  s + t + u + v + w + x + y + z
end

# ---- a deliberately large frame --------------------------------------------
#
# Thirty-two values that are all live across the same loop, so code generation
# has nowhere to keep them but the stack. One function, so the frame the report
# shows is this function's own and not a sum over a path.

def st_wide(cnt, n_cnt, a, b)
  v00 = a + 2;   v01 = a + 3;   v02 = a + 5;   v03 = a + 7
  v04 = a + 11;  v05 = a + 13;  v06 = a + 17;  v07 = a + 19
  v08 = b + 23;  v09 = b + 29;  v10 = b + 31;  v11 = b + 37
  v12 = b + 41;  v13 = b + 43;  v14 = b + 47;  v15 = b + 53
  v16 = a * 59;  v17 = a * 61;  v18 = a * 67;  v19 = a * 71
  v20 = a * 73;  v21 = a * 79;  v22 = a * 83;  v23 = a * 89
  v24 = b * 97;  v25 = b * 101; v26 = b * 103; v27 = b * 107
  v28 = b * 109; v29 = b * 113; v30 = b * 127; v31 = b * 131
  i = 0
  while i < 8
    v00 = v00 + v31; v01 = v01 + v00; v02 = v02 + v01; v03 = v03 + v02
    v04 = v04 + v03; v05 = v05 + v04; v06 = v06 + v05; v07 = v07 + v06
    v08 = v08 + v07; v09 = v09 + v08; v10 = v10 + v09; v11 = v11 + v10
    v12 = v12 + v11; v13 = v13 + v12; v14 = v14 + v13; v15 = v15 + v14
    v16 = v16 + v15; v17 = v17 + v16; v18 = v18 + v17; v19 = v19 + v18
    v20 = v20 + v19; v21 = v21 + v20; v22 = v22 + v21; v23 = v23 + v22
    v24 = v24 + v23; v25 = v25 + v24; v26 = v26 + v25; v27 = v27 + v26
    v28 = v28 + v27; v29 = v29 + v28; v30 = v30 + v29; v31 = v31 + v30
    cnt[0] += 1
    i += 1
  end
  # ONE TERM PER STATEMENT, deliberately, and not a 32-term expression.
  # MEASURED, 2026-09-21: the contract reader's inference is exponential in
  # the DEPTH of a nested binary-operator expression, not in the number of
  # terms. `spinel-typedump <file> ast` on a chain of n additions took 0.003 s
  # at n=4, 0.069 at 12, 0.97 at 16 and 3.9 at 18 -- about four times longer
  # for every two terms -- while Ruby's own parser took 6 ms on the same file
  # and the same 18 terms accumulated through a variable took 4.5 ms. At 32
  # terms it does not finish. Written as an expression this fixture hangs the
  # build; written as statements it is instant and the frame is the same.
  s = 0
  s = s + v00; s = s + v01; s = s + v02; s = s + v03
  s = s + v04; s = s + v05; s = s + v06; s = s + v07
  s = s + v08; s = s + v09; s = s + v10; s = s + v11
  s = s + v12; s = s + v13; s = s + v14; s = s + v15
  s = s + v16; s = s + v17; s = s + v18; s = s + v19
  s = s + v20; s = s + v21; s = s + v22; s = s + v23
  s = s + v24; s = s + v25; s = s + v26; s = s + v27
  s = s + v28; s = s + v29; s = s + v30; s = s + v31
  s
end

# ---- a shallow entry, for the comparison to mean something -----------------

def st_leaf(cnt, n_cnt, a)
  cnt[0] += 1
  a + 1
end
