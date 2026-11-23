require "bpf"

# P026 E120: xdp / tc の context の field — xdp の ingress_ifindex を Out[0]、tc の egress の len を Out[1] に書き mark に 42、ingress は mark を Out[2]、
# 7 を足して書き読み直しを Out[3]
Out = BPF::ArrayMap.new("Out", :u32, 4)

def ifx(ctx)
  Out.update(0, ctx.ingress_ifindex)
  BPF::XDP_PASS
end

def mark_out(skb)
  Out.update(1, skb.len)
  skb.mark = 42
  BPF::TC_PASS
end

def mark_in(skb)
  Out.update(2, skb.mark)
  skb.mark = (skb.mark + 7) & 0xFFFF_FFFF
  Out.update(3, skb.mark)
  BPF::TC_PASS
end
BPF.xdp :ifx
BPF.tcx :mark_out, :egress
BPF.tcx :mark_in, :ingress
