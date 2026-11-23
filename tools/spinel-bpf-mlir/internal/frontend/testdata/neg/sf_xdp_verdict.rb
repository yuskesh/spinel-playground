require "bpf"

# P026 E126: socket_filter が XDP の判定を返す
def p(skb)
  BPF::XDP_PASS
end
BPF.socket_filter :p
# want: SB028 5:3
