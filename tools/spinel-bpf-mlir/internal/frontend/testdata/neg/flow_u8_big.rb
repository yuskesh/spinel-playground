require "bpf"

# P026 E130: ip_proto (u8) に 256
def p(ctx)
  ctx.set_key(:ip_proto, 256)
  BPF::FLOW_OK
end
BPF.flow_dissector :p
# want: SB014 5:26
