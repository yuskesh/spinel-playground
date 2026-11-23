require "bpf"

Out = BPF::ArrayMap.new("Out", :u64, 18)
Seen = BPF::ArrayMap.new("Seen", :u32, 1)

# E016 の表の program — 読みの種類・0x80 以上の byte・window の中の window・u8 から作る可変の offset・map の present の中の外の window。
# 行末の印 (# M1 等) は変異の対照が書き換える op の行 (P004 §5)。
def t(ctx)
  w = ctx.check(0, 14)
  if w
    Out.update(0, w.u8(0))
    Out.update(1, w.u8(13))
    Out.update(2, w.be16(0))
    Out.update(3, w.le16(0))
    Out.update(4, w.be16(12)) # M2
    Out.update(5, w.be32(2))
    Out.update(6, w.le32(2))
    Out.update(7, w.be32(10))
    Out.update(8, w.u8(7)) # M5
    off = 14 + (w.u8(1) & 0x3F)
    v = ctx.check(off, 4)
    if v
      Out.update(9, v.be32(0))
      Out.update(10, w.u8(2))
    else
      Out.update(11, off)
    end
  else
    Out.update(12, 1)
  end
  x = ctx.check(14, 4)
  if x
    r = 1 # M4a
  else
    r = 2 # M4b
  end
  Out.update(13, r)
  y = ctx.check(14, 20) # M3
  if y
    Out.update(14, y.u8(0))
    Out.update(15, y.be16(2))
    p = Seen.lookup(0)
    if p
      Out.update(16, y.u8(9) + (p.load & 0xFF))
    end
  end
  z = ctx.check(40, 6) # M1
  if z
    Out.update(17, z.be16(4))
  end
  BPF::XDP_PASS
end
BPF.xdp :t
