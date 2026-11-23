require "bpf"

# P019 E076: 未知の向き
def p(skb)
  BPF::TC_PASS
end
BPF.tcx :p, :both
# want: SB008 7:1
