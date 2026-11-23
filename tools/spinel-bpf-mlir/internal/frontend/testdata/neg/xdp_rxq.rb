require "bpf"

# P026 E120: xdp の context に表に無い field (rx_queue_index)
Out = BPF::ArrayMap.new("Out", :u32, 1)

def p(ctx)
  Out.update(0, ctx.rx_queue_index)
  BPF::XDP_PASS
end
BPF.xdp :p
# want: SB002 7:17
