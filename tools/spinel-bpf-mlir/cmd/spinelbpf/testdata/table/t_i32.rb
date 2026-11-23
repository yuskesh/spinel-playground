require "bpf"

In = BPF::ArrayMap.new("In", :i32, 2)
Out = BPF::ArrayMap.new("Out", :i64, 37)
O32 = BPF::ArrayMap.new("O32", :i32, 2)
OU = BPF::ArrayMap.new("OU", :u32, 2)

def prog(ctx)
  a = 0
  b = 0
  p = In.lookup(0)
  if p
    a = p.load
  end
  q = In.lookup(1)
  if q
    b = q.load
  end
  Out.update(0, a + b)
  Out.update(1, a - b)
  Out.update(2, a * b)
  Out.update(3, -a)
  Out.update(4, ~a)
  Out.update(5, a & b)
  Out.update(6, a | b)
  Out.update(7, a ^ b)
  Out.update(8, a << 1)
  Out.update(9, a << 31)
  Out.update(10, b << 17)
  Out.update(11, a >> 1)
  Out.update(12, a >> 31)
  Out.update(13, a >> 63)
  Out.update(14, a / 1)
  Out.update(15, a / 2)
  Out.update(16, a / -8)
  Out.update(17, a % 8)
  Out.update(18, a % -8)
  O32.update(0, a)
  O32.update(1, (a & 0x7FFF_FFFF) - 1)
  OU.update(0, a & 0xFFFF_FFFF)
  OU.update(1, a + 2147483648)
  BPF::XDP_PASS
end
BPF.xdp :prog
