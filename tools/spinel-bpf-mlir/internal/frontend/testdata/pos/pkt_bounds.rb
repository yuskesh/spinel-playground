require "bpf"

Out = BPF::ArrayMap.new("Out", :u32, 4)

# 境界: 長さ 1 と 65535、offset の上限 65535 − N、添字の上限 i + 幅 = N (P004 E014)
def bounds(ctx)
  a = ctx.check(65521, 14)
  if a
    Out.update(0, a.be16(12))
  end
  b = ctx.check(0, 1)
  if b
    Out.update(1, b.u8(0))
  end
  c = ctx.check(0, 65535)
  if c
    Out.update(2, c.u8(65534))
  end
  d = ctx.check(65535 - 4, 4)
  if d
    Out.update(3, d.le32(0))
  end
  BPF::XDP_PASS
end
BPF.xdp :bounds
