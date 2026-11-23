require "bpf"

In = BPF::ArrayMap.new("In", :u32, 2)
Out = BPF::ArrayMap.new("Out", :i64, 17)
OU = BPF::ArrayMap.new("OU", :u32, 4)

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
  Out.update(2, (a & 0xFFFF) * b)
  Out.update(3, a >> 5)
  Out.update(4, a << 31)
  Out.update(5, a / 3)
  Out.update(6, a % 7)
  Out.update(7, a & b)
  Out.update(8, a | b)
  Out.update(9, a ^ b)
  Out.update(10, ~a)
  Out.update(11, a < b ? 1 : 0)
  Out.update(12, a >= 2147483648 ? 1 : 0)
  Out.update(13, -a)
  Out.update(14, a)
  Out.update(15, a % 4294967296)
  Out.update(16, a / 65536)
  OU.update(0, (a + b) & 0xFFFF_FFFF)
  OU.update(1, (a * 3) & 0xFFFF_FFFF)
  OU.update(2, a ^ 0xFFFF_FFFF)
  OU.update(3, a >> 1)
  BPF::XDP_PASS
end
BPF.xdp :prog
