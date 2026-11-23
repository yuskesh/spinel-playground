require "bpf"

# P019 E076: sched_cls の program が XDP の判定を返す (XDP_PASS = 2 = TC_DROP — 値が重なる)
def p(skb)
  BPF::XDP_PASS
end
BPF.tcx :p, :ingress
# want: SB028 5:3
