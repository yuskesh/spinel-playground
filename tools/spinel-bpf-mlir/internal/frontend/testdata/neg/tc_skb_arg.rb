require "bpf"

# P019 E076: skb の context に tracing の API (xdp_ctx_arg.rb と同じ診断)
Counts = BPF::ArrayMap.new("Counts", :u64, 2)

def p(skb)
  Counts.atomic_add(0, skb.arg(1))
  BPF::TC_PASS
end
BPF.tcx :p, :ingress
# want: SB002 7:24
