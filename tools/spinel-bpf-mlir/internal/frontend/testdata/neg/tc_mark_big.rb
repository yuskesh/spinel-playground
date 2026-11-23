require "bpf"

# P026 E120: mark に 2^32 (u32 の外)
def p(skb)
  skb.mark = 4294967296
  BPF::TC_PASS
end
BPF.tcx :p, :ingress
# want: SB014 5:14
