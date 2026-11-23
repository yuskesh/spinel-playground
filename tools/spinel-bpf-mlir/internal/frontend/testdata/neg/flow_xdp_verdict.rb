require "bpf"

# P026 E130: flow_dissector が XDP の判定を返す
def p(ctx)
  BPF::XDP_PASS
end
BPF.flow_dissector :p
# want: SB028 5:3
