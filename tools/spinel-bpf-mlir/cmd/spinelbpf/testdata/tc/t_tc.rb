require "bpf"

OutX = BPF::ArrayMap.new("OutX", :u64, 18)
OutT = BPF::ArrayMap.new("OutT", :u64, 18)
Seen = BPF::ArrayMap.new("Seen", :u32, 1)

# E078 (P019): t_pkt (E016) の読みの本体を XDP の root (t_x → OutX) と sched_cls の root (t_c → OutT) に同じ形で 2 回
# (eBPF の側の利用者の def の呼び出しは部分集合の外 — E076)。t_c は byte 13 の低位の bit で drop する guard を持つ (判定の変異の元)。
# 行末の印 (# TM3・# TG) は変異の対照が書き換える行。
def t_x(ctx)
  w = ctx.check(0, 14)
  if w
    OutX.update(0, w.u8(0))
    OutX.update(1, w.u8(13))
    OutX.update(2, w.be16(0))
    OutX.update(3, w.le16(0))
    OutX.update(4, w.be16(12))
    OutX.update(5, w.be32(2))
    OutX.update(6, w.le32(2))
    OutX.update(7, w.be32(10))
    OutX.update(8, w.u8(7))
    off = 14 + (w.u8(1) & 0x3F)
    v = ctx.check(off, 4)
    if v
      OutX.update(9, v.be32(0))
      OutX.update(10, w.u8(2))
    else
      OutX.update(11, off)
    end
  else
    OutX.update(12, 1)
  end
  x = ctx.check(14, 4)
  if x
    r = 1
  else
    r = 2
  end
  OutX.update(13, r)
  y = ctx.check(14, 20)
  if y
    OutX.update(14, y.u8(0))
    OutX.update(15, y.be16(2))
    p = Seen.lookup(0)
    if p
      OutX.update(16, y.u8(9) + (p.load & 0xFF))
    end
  end
  z = ctx.check(40, 6)
  if z
    OutX.update(17, z.be16(4))
  end
  BPF::XDP_PASS
end

def t_c(skb)
  d = 0
  w = skb.check(0, 14)
  if w
    OutT.update(0, w.u8(0))
    OutT.update(1, w.u8(13))
    OutT.update(2, w.be16(0))
    OutT.update(3, w.le16(0))
    OutT.update(4, w.be16(12))
    OutT.update(5, w.be32(2))
    OutT.update(6, w.le32(2))
    OutT.update(7, w.be32(10))
    OutT.update(8, w.u8(7))
    d = w.u8(13) & 1
    off = 14 + (w.u8(1) & 0x3F)
    v = skb.check(off, 4)
    if v
      OutT.update(9, v.be32(0))
      OutT.update(10, w.u8(2))
    else
      OutT.update(11, off)
    end
  else
    OutT.update(12, 1)
  end
  x = skb.check(14, 4)
  if x
    r = 1
  else
    r = 2
  end
  OutT.update(13, r)
  y = skb.check(14, 20) # TM3
  if y
    OutT.update(14, y.u8(0))
    OutT.update(15, y.be16(2))
    p = Seen.lookup(0)
    if p
      OutT.update(16, y.u8(9) + (p.load & 0xFF))
    end
  end
  z = skb.check(40, 6)
  if z
    OutT.update(17, z.be16(4))
  end
  return BPF::TC_DROP if d == 1 # TG
  BPF::TC_PASS
end
BPF.xdp :t_x
BPF.tcx :t_c, :ingress
