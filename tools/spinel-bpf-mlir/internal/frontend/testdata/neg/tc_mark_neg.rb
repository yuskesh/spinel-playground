require "bpf"

# P026 E120: mark に負の値 (u32 の外)
def p(skb)
  skb.mark = -1
  BPF::TC_PASS
end
BPF.tcx :p, :ingress
# want: SB014 5:14
