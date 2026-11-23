require "bpf"

# P026 E130: struct bpf_flow_keys に無い field の名前
def p(ctx)
  return BPF::FLOW_DROP if ctx.key(:vlan) == 1
  BPF::FLOW_OK
end
BPF.flow_dissector :p
# want: SB002 5:36
