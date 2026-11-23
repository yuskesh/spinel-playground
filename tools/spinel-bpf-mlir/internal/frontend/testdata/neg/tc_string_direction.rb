require "bpf"

# P019 E076: 向きは Symbol の literal (String は受けない)
def p(skb)
  BPF::TC_PASS
end
BPF.tcx :p, "ingress"
# want: SB008 7:1
