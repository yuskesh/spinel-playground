require "bpf"

# P026 E120: xdp の ingress_ifindex の書き (読みだけ)
def p(ctx)
  ctx.ingress_ifindex = 1
  BPF::XDP_PASS
end
BPF.xdp :p
# want: SB002 5:3
