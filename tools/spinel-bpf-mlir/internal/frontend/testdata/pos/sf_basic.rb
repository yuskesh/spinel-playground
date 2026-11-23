require "bpf"

# P026 E126: socket_filter — __sk_buff の len を Out[0] に、64 を超えれば捨てる (guard)、それ以外は全 byte を受ける
Out = BPF::ArrayMap.new("Out", :u32, 1)

def short_only(skb)
  n = skb.len
  Out.update(0, n)
  return BPF::SF_DROP if n > 64
  BPF::SF_KEEP
end
BPF.socket_filter :short_only
