require "bpf"

# P026 E130: xdp の program が flow_dissector の判定を返す
def p(ctx)
  BPF::FLOW_OK
end
BPF.xdp :p
# want: SB028 5:3
