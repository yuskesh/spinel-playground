# The Full side of the adapter, compiled by the PINNED compiler.
#
# It uses the generated module rather than the raw ffi_func bindings, because
# the module is what a Full caller is given: the decode of a signed load and the
# word transport are its job, and calling the C operations directly would be
# testing something no caller does.
require_relative "core_sum_u8"

M = CoreBoundarySumU8

puts M.startup

b = M.allocate_storage(M::ELEM_U8, 4)
r = M.allocate_storage(M::ELEM_I64, 1)
w = M.allocate_storage(M::ELEM_U32, 2)
i = M.allocate_storage(M::ELEM_I32, 1)

M.store(b, 0, 10)
M.store(b, 1, 20)
M.store(b, 2, 30)
M.store(b, 3, 40)
puts M.load(b, 2, M::ELEM_U8)

# The same 32 bits, decoded for the element type it was stored as and left
# alone for the one it was not.
M.store(i, 0, -1)
puts M.load(i, 0, M::ELEM_I32)
puts M.load(i, 0, M::ELEM_U32)

puts M.invoke(b, r)
M.load_i64_words(r, 0, w, 0, 1)
puts M.load(w, 0, M::ELEM_U32)
puts M.load(w, 1, M::ELEM_U32)

# INT64_MIN, which this pin cannot return through an `:int64` at all, carried
# as two unsigned words instead.
M.store_i64_words(r, 0, 0, 2147483648)
M.load_i64_words(r, 0, w, 0, 1)
puts M.load(w, 0, M::ELEM_U32)
puts M.load(w, 1, M::ELEM_U32)

puts M.load(b, 9, M::ELEM_U8)
puts M.invoke(b, b)
puts M.release(b)
puts M.release(b)

# Decision 0018's narrow elements. A signed one comes back sign-extended to its
# 32-bit pattern, so the one decode serves i8, i16 and i32 alike; named as
# another element, the same pattern is left alone.
n8 = M.allocate_storage(M::ELEM_I8, 1)
n16 = M.allocate_storage(M::ELEM_I16, 1)
u16 = M.allocate_storage(M::ELEM_U16, 1)
M.store(n8, 0, -128)
M.store(n16, 0, -32768)
M.store(u16, 0, 65535)
puts M.load(n8, 0, M::ELEM_I8)
puts M.load(n8, 0, M::ELEM_U32)
puts M.load(n16, 0, M::ELEM_I16)
puts M.load(u16, 0, M::ELEM_U16)
puts M.store(n8, 0, 128)
puts M.load(n8, 0, M::ELEM_I8)
