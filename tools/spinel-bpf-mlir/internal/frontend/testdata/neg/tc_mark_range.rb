require "bpf"

# P026 E120: mark に区間が u32 を越える値 (w.be32(0) + 1)
def p(skb)
  x = 0
  w = skb.check(0, 14)
  if w
    x = w.be32(0) + 1
  end
  skb.mark = x
  BPF::TC_PASS
end
BPF.tcx :p, :egress
# want: SB014 10:14
