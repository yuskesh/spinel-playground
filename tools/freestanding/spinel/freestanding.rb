# spinel/freestanding.rb -- the boundary-declaration surface (E040, P003 Phase 1).
#
#     require_relative "spinel/freestanding"
#     freestanding_def :add, params: [:i32, :i32], returns: :i32
#     def add(a, b)
#       a + b
#     end
#
# Exactly the shape `spinel/tensor.rb` gave `tensor_def` (R004 design A): a
# no-op call at run time and a RECORD at compile time, which
# `spinel-mlirgen --freestanding` reads back out of `--dump-ast`.  Ruby gets no
# new syntax -- the plan's review refused `def add(a : Int32, b : Int32)`
# because that would be a language change in vendor/spinel, and vendor/spinel is
# read-only.
#
# WHY A DECLARATION AT ALL, when spinel already infers types?  Because inference
# answers a different question.  It says "this method computes on Integers", and
# in a Spinel program that is the whole truth: `mrb_int` is 64 bits and the C
# boundary is spinel's own.  Here the boundary is somebody else's C -- Zephyr's
# -- and `int32_t` versus `int64_t` is a fact about THAT side, which no amount of
# looking at the Ruby can recover.  So the declaration states it, the generator
# emits an adapter (extend in, checked narrow out), and the exported prototype is
# written out by `--emit-header` so nobody transcribes it by hand.
#
#   params:    Array of boundary entries, one per parameter.  [] for none.
#              Three shapes, and one entry is always exactly one C parameter and
#              one Ruby parameter (E077):
#                scalar   :i8 :i16 :i32 :i64 :u8 :u16 :u32 :f32 :f64
#                buffer   [:<elem>_buf, :<dir>]   elem as above, dir in/out/inout
#                length   :len       the length of the buffer(s) just before it
#   returns:   the boundary type of the return value.  Required -- the integer
#              subset has no void method.  SCALAR only: a buffer belongs to the
#              caller, so there is nothing for the kernel to hand back (write
#              into an :out buffer and return a count).
#   export:    the C symbol.  Default `spinel_<name>`.
#   overflow:  :trap (default, from the profile) or :wrap.  P003 decision record
#              D-2: :raise cannot exist without a heap and a setjmp stack, and
#              asking for it is an error rather than a silent downgrade.
#   bounds:    :trap (default) or :unchecked.  E077 decision record D-5.  Only
#              means something for a declaration that has a buffer.
#
# THE BUFFER BOUNDARY, stated once (E077 / P003 Phase 2).  A buffer parameter is
# an address the CALLER owns; the freestanding subset still allocates nothing.
# What the kernel may do with it is index it -- `b[i]` and `b[i] = v` -- and
# that is the whole surface.  Two halves of the contract are enforced in two
# different places, and which half goes where is decided by what can be decided
# statically:
#
#   direction   `b[i] = v` on an :in buffer does not COMPILE.  The generated C
#               prototype even spells it `const`, so the platform's own compiler
#               enforces the same rule independently.
#   range       `0 <= i < len` is a RUN-TIME check (trap code 4), because an
#               index is a value.  Under `bounds: :unchecked` it is the caller's
#               problem; the NULL-buffer (5) and negative-length (6) checks at
#               the entry stay either way, because those are about the CALL.
#
# What the range check claims is "the kernel stays inside the length it was
# given" -- NOT "the length is true".  A caller that passes (buf, 9) for a
# five-element buffer gets nine elements read, and no check can see that.
#
# THERE IS NO STRUCT.  A record at the boundary is a stride and a set of
# offsets: `rec[i + FIELD]`, with `i` stepping by the stride.  C ABI struct
# passing is per-target law (AAPCS, the RISC-V flattening rules, wasm32's byval
# pointer) and P003 design principle 10 leaves that kind of thing to LLVM; the
# MLIR func->llvm conversion does not do it either.  See the E077 decision
# record for the escape hatch (an opaque pointer plus accessor externs, which
# needs P003 Phase 4).
#
# THE VALUE MODEL, stated once so that the deviation from Ruby is on the record:
# a freestanding Integer is a fixed-width two's-complement integer.  Ruby's
# Integer is arbitrary precision; Bignum promotion needs an allocator and there
# is none, so under :trap an overflow calls the platform's trap hook and never
# returns, and under :wrap it wraps.  Internally the arithmetic is 64-bit (that
# is what spinel's inference assumed when it typed the method), and the declared
# width applies AT THE BOUNDARY: a return value that does not fit is a trap, not
# a truncation.
#
# A freestanding Float is an IEEE 754 DOUBLE, and here the deviation runs the
# other way: there is none.  Ruby's Float is a double too (mrb_float), so the
# body computes in f64 (E077 decision record D-4, which is D-1 again) and every
# answer -- overflow to +/-inf, 1.0/0.0 = Infinity, 0.0/0.0 = NaN -- is Ruby's
# own answer, with no check added.  `:f32` is an adapter at the boundary and it
# ROUNDS; it does not trap, because "does it fit" is not a question a float has.
# `Float#%` is refused: it is floored modulo, which needs fmod from libm.
#
# A file using these declarations is compiled by spinel-mlirgen, never by
# `spinel` into a program -- there is no host program here at all.  The methods
# still have to type-check as ordinary Spinel, which is what `--emit-types`
# checks and how the int-only guard keeps working.

def freestanding_def(name, params: [], returns: :i32, export: :"", overflow: :trap,
                     bounds: :trap)
  0
end
