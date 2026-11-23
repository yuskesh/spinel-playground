require "bpf"

# P026 E130: ipv6_src の添字 4 (0..3 の外)
def p(ctx)
  ctx.set_key(:ipv6_src, 4, 1)
  BPF::FLOW_OK
end
BPF.flow_dissector :p
# want: SB014 5:26
