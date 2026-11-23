require "bpf"

# P019 E076: 向きの無い BPF.tcx
def p(skb)
  BPF::TC_PASS
end
BPF.tcx :p
# want: SB008 7:1
