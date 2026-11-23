require "bpf"

In = BPF::ArrayMap.new("In", :i32, 2)
Out = BPF::ArrayMap.new("Out", :i64, 37)

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
  Out.update(19, a / 2147483648)
  Out.update(20, a % 4611686018427387904)
  Out.update(21, (a & 0x7FFF_FFFF) / 7)
  Out.update(22, (a & 0x7FFF_FFFF) % 10)
  Out.update(23, a < b ? 1 : 0)
  Out.update(24, a <= b ? 1 : 0)
  Out.update(25, a > b ? 1 : 0)
  Out.update(26, a >= b ? 1 : 0)
  Out.update(27, a == b ? 1 : 0)
  Out.update(28, a != b ? 1 : 0)
  Out.update(29, (a < 0 && b > 0) ? 1 : 0)
  Out.update(30, (a == 0 || !(b >= 7)) ? 1 : 0)
  Out.update(31, a + b * 3)
  Out.update(32, a - b - 5)
  Out.update(33, a | b ^ 3 & a)
  Out.update(34, a & b == b ? 1 : 0)
  Out.update(35, a / 4 * 2)
  x = 0
  if a < -100
    x = 1
  elsif a < 100
    x = 2
  else
    x = 3
  end
  unless b == 0
    x += 10
  end
  Out.update(36, x)
  BPF::XDP_PASS
end
BPF.xdp :prog
