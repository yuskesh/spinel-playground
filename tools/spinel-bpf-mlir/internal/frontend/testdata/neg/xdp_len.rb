require "bpf"

# P026 E126: xdp の context の len (E126 では socket_filter だけ)
Out = BPF::ArrayMap.new("Out", :u32, 1)

def p(ctx)
  Out.update(0, ctx.len)
  BPF::XDP_PASS
end
BPF.xdp :p
# want: SB002 7:17
