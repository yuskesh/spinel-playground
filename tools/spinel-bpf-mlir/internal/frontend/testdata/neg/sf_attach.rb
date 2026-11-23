require "bpf"

# P026 E126: socket_filter に attach の向き (attach の句は無い)
def p(skb)
  BPF::SF_KEEP
end
BPF.socket_filter :p, :ingress
# want: SB008 7:1
