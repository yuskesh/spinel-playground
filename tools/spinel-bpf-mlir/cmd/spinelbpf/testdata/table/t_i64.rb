require "bpf"

In = BPF::ArrayMap.new("In", :i64, 2)
Out = BPF::ArrayMap.new("Out", :i64, 20)

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
  Out.update(0, a >> 3)
  Out.update(1, a >> 63)
  Out.update(2, a & 255)
  Out.update(3, a & b)
  Out.update(4, a | b)
  Out.update(5, a ^ b)
  Out.update(6, ~a)
  Out.update(7, a / 8)
  Out.update(8, a % 8)
  Out.update(9, a / -4611686018427387904)
  Out.update(10, a % -4)
  Out.update(11, a < b ? 1 : 0)
  Out.update(12, a == b ? 1 : 0)
  Out.update(13, a >= 0 ? 1 : 0)
  Out.update(14, (a & 0xFFFF) + (b & 0xFFFF))
  Out.update(15, (a & 0xFFFF_FFFF) * (b & 0xFFFF))
  Out.update(16, a / 1)
  Out.update(17, (a >> 1) - (b >> 1))
  Out.update(18, a > b ? a : b)
  Out.update(19, a != 0 && b != 0 ? 1 : 0)
  BPF::XDP_PASS
end
BPF.xdp :prog
