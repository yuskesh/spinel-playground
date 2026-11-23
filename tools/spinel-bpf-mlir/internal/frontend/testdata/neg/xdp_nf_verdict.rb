require "bpf"

# P026 E128: xdp の program が netfilter の判定を返す
def p(ctx)
  BPF::NF_ACCEPT
end
BPF.xdp :p
# want: SB028 5:3
