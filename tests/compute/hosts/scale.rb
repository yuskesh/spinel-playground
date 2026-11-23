n = 4
w = IO::Buffer.new(n * 4)
Scale.open(n)
Scale.v_write(i32s([1, -2, 3, 2147483647]))
Scale.dispatch(n)
Scale.w_read(w)
Scale.close
want = [4, -5, 10, 2147483646]
n.times { |i| check("scale #{i}", read_i32(w, i), want[i]) }
