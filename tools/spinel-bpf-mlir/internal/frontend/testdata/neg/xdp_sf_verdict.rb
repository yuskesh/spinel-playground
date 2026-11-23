require "bpf"

# P026 E126: xdp の program が socket_filter の判定を返す
def p(ctx)
  BPF::SF_KEEP
end
BPF.xdp :p
# want: SB028 5:3
