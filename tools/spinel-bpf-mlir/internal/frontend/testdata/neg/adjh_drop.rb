require "bpf"

# P026 E122: adjust_head の status を捨てる文
def p(ctx)
  ctx.adjust_head(4)
  BPF::XDP_PASS
end
BPF.xdp :p
# want: SB026 5:3
