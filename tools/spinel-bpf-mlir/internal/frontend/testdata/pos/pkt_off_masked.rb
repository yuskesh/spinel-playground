require "bpf"

Off = BPF::ArrayMap.new("Off", :u32, 1)
Out = BPF::ArrayMap.new("Out", :u32, 1)

# map の値を offset に — `& 0xFFF` で区間を [0, 4095] に狭めれば受ける (P004 §2・E014)
def masked(ctx)
  p = Off.lookup(0)
  if p
    w = ctx.check(p.load & 0xFFF, 2)
    if w
      Out.update(0, w.be16(0))
    end
  end
  BPF::XDP_PASS
end
BPF.xdp :masked
