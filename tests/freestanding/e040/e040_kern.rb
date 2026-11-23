# E040 kernel file -- P003 Phase 1 (M1).
#
# The KERNEL WORLD of the freestanding surface: `freestanding_def` declarations
# plus the methods they name.  There is no top-level program here at all -- this
# file is never run and never linked into a Spinel binary; it is compiled by
#
#   spinel-mlirgen e040_kern.rb --freestanding --profile <profile>.yaml -o kern.o
#
# and the .o is handed to Zephyr's linker.  The HOST oracle (e040_host.rb) is
# generated from THIS file by mkcases.py, which strips the declaration lines and
# appends a driver, so the method bodies on both sides are byte-identical by
# construction rather than by proofreading (rewrite.diff records the delta).
#
# NOTE on method names: a top-level method here becomes `sp_<name>` in the
# generated C, and spinel's runtime already defines sp_idiv / sp_imod as
# `static inline` in spinel_rt.h -- so the HOST oracle of a method called `idiv`
# does not compile ("redefinition of 'sp_idiv'").  Hence `qdiv`.  The
# freestanding object does not have the problem (it links no runtime at all and
# its sp_* bodies have internal linkage), which is why it only shows up on the
# oracle side.  src/codegen.c:1630 anticipates exactly this collision.
require_relative "spinel/freestanding"

# ---- the first milestone's exit sentence: add(a, b) on an MCU -----------
freestanding_def :add, params: [:i32, :i32], returns: :i32
def add(a, b)
  a + b
end

# ---- the R006 s5 trio, now with an i32 boundary --------------------------
# These are the methods R006 P6 ran on the M33 at i64 boundaries; keeping them
# is what makes the E018/E022 measured answers reusable as expected values.
freestanding_def :fib, params: [:i32], returns: :i32
def fib(n)
  return n if n < 2
  fib(n - 1) + fib(n - 2)
end

# `%` is floored in Ruby (the sign follows the divisor), which is NOT what
# LLVM's srem does; the generator emits sp_imod's correction sequence.  In the
# i64 body it pulled in __aeabi_ldivmod / __moddi3; the 32-bit body needs no
# helper.
freestanding_def :igcd, params: [:i32, :i32], returns: :i32
def igcd(a, b)
  while b != 0
    a, b = b, a % b
  end
  a
end

# A callee (igcd) reached from a second entry: the closure has to pull it in
# once, not twice, and both entries must agree on the overflow policy.
freestanding_def :sumsq, params: [:i32], returns: :i32
def sumsq(n)
  s = 0
  i = 1
  while i <= n
    s += i * i
    i += 1
  end
  s + igcd(s, n)
end

# ---- the boundary itself ---------------------------------------------------
# This file computes at the target's width, 32 bits on every target it is built
# for (decision 0019, revised 2026-10-21): the i64 boundaries `mulwide` and
# `bigmul` are in e040_wide.rb, which only a 64-bit host builds.
#
# A multiplication narrowed to i32.  46341 * 46341 does not fit i32, and this
# is what R006 H1 asked about; in a 32-bit body the product itself overflows
# (code 1) before the boundary sees it.
freestanding_def :mulnarrow, params: [:i32, :i32], returns: :i32
def mulnarrow(a, b)
  a * b
end

# `overflow: :wrap` opt-in (P003 decision record D-2).  Same expression, same
# arguments, deliberately different answer -- and the difference is DECLARED.
freestanding_def :mulwrap, params: [:i32, :i32], returns: :i32, overflow: :wrap
def mulwrap(a, b)
  a * b
end

# Division: the zero divisor is trap code 2.  (On a Cortex-M an unguarded sdiv
# by zero is a Hard Fault or a defined 0 depending on CCR.DIV_0_TRP; neither is
# an answer, so the check stays even in `wrap`.)
freestanding_def :qdiv, params: [:i32, :i32], returns: :i32
def qdiv(a, b)
  a / b
end

# ---- the C ABI boundary, exercised on purpose -----------------------------
# FOUR i32 parameters.  Under AAPCS these live in r0-r3; if the boundary were
# i64 (the pre-E040 canonical ABI) they would take r0:r1, r2:r3 and the stack,
# and the answer would be wrong.  So this single case discriminates the two
# calling conventions at run time (P003 Phase 2's ABI suite in miniature).
freestanding_def :abi4, params: [:i32, :i32, :i32, :i32], returns: :i32
def abi4(a, b, c, d)
  a - b + c - d
end

# Unsigned and narrow boundaries: :u8 in, :u8 out, zero-extended both ways.
freestanding_def :u8clamp, params: [:u8, :u8], returns: :u8
def u8clamp(a, b)
  a + b
end

# A signed narrow return: -1 must arrive as (int8_t)-1, not 255.
freestanding_def :i8neg, params: [:i32], returns: :i8
def i8neg(n)
  0 - n
end

# No parameters at all, an unsigned boundary and a renamed export symbol.
freestanding_def :ver, params: [], returns: :u16, export: :spinel_abi_version
def ver
  4004
end
