require "bpf"

# P026 E120: socket_filter の context の mark (packet を持たない context — len だけ)
Out = BPF::ArrayMap.new("Out", :u32, 1)

def p(skb)
  Out.update(0, skb.mark)
  BPF::SF_KEEP
end
BPF.socket_filter :p
# want: SB028 7:17
