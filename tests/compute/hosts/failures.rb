def refused(label, needle)
  begin
    yield
    check(label, "no error", needle)
  rescue => e
    check(label, e.message.include?(needle), true)
  end
end
n = 8
xs = f32s([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0])
out = IO::Buffer.new(n * 4)
refused("open before a good open: not a multiple", "not a multiple") { Reduce.open(6) }
refused("open: over the workgroup limit", "workgroups is over") { Reduce.open(262144) }
refused("write before open", "not open") { Reduce.x_write(xs) }
Reduce.open(n)
refused("open twice", "already open") { Reduce.open(n) }
refused("short buffer", "bytes") { Reduce.x_write(IO::Buffer.new(4)) }
refused("dispatch over capacity", "over the opened capacity") { Reduce.dispatch(16) }
refused("dispatch not a multiple", "not a multiple") { Reduce.dispatch(6) }
Reduce.x_write(xs)
Reduce.dispatch(n)
Reduce.partial_read(out)
check("a good run still works", read_f32(out, 0), 10.0)
Reduce.dispatch(n)
Reduce.partial_read(out)
check("dispatch again keeps the buffers", read_f32(out, 1), 26.0)
Reduce.close
refused("close twice", "not open") { Reduce.close }
refused("dispatch after close", "not open") { Reduce.dispatch(n) }
refused("open after close", "closed") { Reduce.open(n) }
