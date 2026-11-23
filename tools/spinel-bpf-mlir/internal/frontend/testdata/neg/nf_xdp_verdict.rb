require "bpf"

# P026 E128: netfilter が XDP の判定を返す
def p(ctx)
  BPF::XDP_PASS
end
BPF.netfilter :p
# want: SB028 5:3
