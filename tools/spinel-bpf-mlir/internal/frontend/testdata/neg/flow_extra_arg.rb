require "bpf"

# P026 E130: flow_dissector の宣言に余分な引数 (netns は user の側の attach_netns)
def p(ctx)
  BPF::FLOW_OK
end
BPF.flow_dissector :p, :x
# want: SB008 7:1
