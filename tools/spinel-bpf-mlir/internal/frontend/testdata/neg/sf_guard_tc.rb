require "bpf"

# P026 E126: socket_filter の guard が sched_cls の判定
def p(skb)
  n = skb.len
  return BPF::TC_DROP if n > 64
  BPF::SF_KEEP
end
BPF.socket_filter :p
# want: SB028 6:10
