# Every value below is derived by hand from the contract in decision 0031.
# a, b, then a/b, a%b, a>>b, a<<b, a<b, a+b, the smaller, the neighbour in the workgroup
rows = [
  [7, 2, 3, 1, 1, 28, 0, 9, 2, -7],
  [-7, 2, -4, 1, -2, -28, 1, -5, -7, 7],
  [7, -2, -4, -1, 0, -1073741824, 0, 5, -2, -7],
  [-7, -2, 3, -1, -1, 1073741824, 1, -9, -7, 7],
  [-2147483648, -1, -2147483648, 0, -1, 0, 1, 2147483647, -2147483648, -2147483648],
  [-2147483648, 0, 0, 0, -2147483648, -2147483648, 1, -2147483648, -2147483648, 5],
  [5, 0, 0, 0, 5, 5, 0, 5, 0, 2147483647],
  [2147483647, -1, -2147483647, 0, 0, -2147483648, 0, 2147483646, -1, -2147483648],
  [2147483647, 1, 2147483647, 0, 1073741823, -2, 0, -2147483648, 1, -2147483648],
  [-2147483648, 2147483647, -2, 2147483646, -1, 0, 1, -1, -2147483648, -1],
  [-1, 31, -1, 30, -1, -2147483648, 1, 30, -1, -16],
  [-16, 33, -1, 17, -8, -32, 1, 17, -16, 2147483647],
  [1, 32, 0, 1, 1, 1, 1, 33, 1, -1],
  [-1, 0, 0, 0, -1, -1, 1, -1, -1, 100],
  [100, -3, -34, -2, 0, -2147483648, 0, 97, -3, -100],
  [-100, 3, -34, 2, -13, -800, 1, -97, -100, 1],
]
n = 128
as = IO::Buffer.new(n * 4)
bs = IO::Buffer.new(n * 4)
rows.size.times do |i|
  as.set_value(:s32, i * 4, rows[i][0])
  bs.set_value(:s32, i * 4, rows[i][1])
end
o = IO::Buffer.new(n * 4)
cnt = IO::Buffer.new(n * 4)
Semantics.open(n)
Semantics.a_write(as)
Semantics.b_write(bs)
Semantics.dispatch(n)
Semantics.o_read(o)
Semantics.cnt_read(cnt)
Semantics.close
rows.size.times do |i|
  8.times { |k| check("row #{i} column #{k}", read_i32(o, i * 8 + k), rows[i][k + 2]) }
end
check("every invocation added once", read_i32(cnt, 0), n)
