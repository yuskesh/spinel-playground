require "bpf"

# P026 E126: socket_filter の context に check (packet を持たない — len だけ)
Out = BPF::ArrayMap.new("Out", :u32, 1)

def p(skb)
  w = skb.check(0, 14)
  if w
    Out.update(0, 1)
  end
  BPF::SF_KEEP
end
BPF.socket_filter :p
# want: SB028 7:7
