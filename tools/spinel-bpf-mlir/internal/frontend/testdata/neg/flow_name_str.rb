require "bpf"

# P026 E130: field の名前が Symbol の literal でない
def p(ctx)
  ctx.set_key("thoff", 14)
  BPF::FLOW_OK
end
BPF.flow_dissector :p
# want: SB002 5:3
