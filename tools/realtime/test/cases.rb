# tools/realtime/test/cases.rb -- the behaviour spinel-rtcheck is pinned to.
#
# One file, one compile, one entry per case (a method has to be REACHABLE from
# main or spinel does not emit it, hence the driver at the bottom).
#
# HALF THE CASES MUST BE ACCEPTED.  A checker that refuses everything is
# trivially sound and worthless; the accept column is what makes the refuse
# column mean something (R006 s6 D-3 recommendation 3, the E031/E033/E038
# rejection-table discipline: keep the control group in the same table).
#
# Some rows below are LIMITATIONS, not desired behaviour, and are marked as
# such in expected.tsv: they are frozen so that improving them shows up as a
# test failure that has to be looked at rather than as silence.

# ---- must be ACCEPTED -----------------------------------------------------

def pure_add(a, b)
  a * b + a - b
end

def pure_loop(n)
  s = 0
  i = 0
  while i < n
    s = s + i
    i = i + 1
  end
  s
end

def ary_get(a, i)
  a[i]
end

def ary_length(a)
  a.length
end

def ivar_free(a, b)
  # nothing but arithmetic and comparison
  a < b ? b - a : a - b
end

# ---- must be REFUSED ------------------------------------------------------

def str_build(n)
  "n=#{n}"
end

def ary_new_each_call(n)
  Array.new(n, 0).length
end

def ary_push(a, v)
  a << v
  a.length
end

# LIMITATION (frozen): the in-bounds arm of `a[i] = v` does not allocate, but
# the grow arm lives in the same runtime function (sp_IntArray_set ->
# sp_IntArray_set_slow -> realloc) and whether i is in bounds is a run-time
# fact.  A function-granularity call graph cannot separate them.
def ary_set(a, i, v)
  a[i] = v
  a.length
end

# LIMITATION (frozen): the raise arm formats its message, and formatting
# allocates.  Strict mode refuses; --allow-abort accepts it because the
# allocation is in a block that cannot reach a `ret`.
def raise_guard(n)
  raise ArgumentError, "negative: #{n}" if n < 0
  n * 2
end

# `loop do ... break ... end` compiles to a setjmp scope, so a longjmp CAN land
# back inside this frame.  --allow-abort must refuse the whole region rather
# than quietly assume the raise never comes back.
def loop_break(n)
  i = 0
  loop do
    i = i + 1
    break if i >= n
  end
  i
end

def main
  a = [1, 2, 3]
  n = ARGV.length
  x = pure_add(n, 2) + pure_loop(n) + ary_get(a, 0) + ary_length(a) + ivar_free(n, 3)
  x = x + str_build(n).bytesize + ary_new_each_call(n + 1) + ary_push(a, n)
  x = x + ary_set(a, 0, n) + raise_guard(n) + loop_break(n + 1)
  puts x
end

main
