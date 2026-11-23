require "bpf"

# P026 E130: sport (u16) に負の値
def p(ctx)
  ctx.set_key(:sport, -1)
  BPF::FLOW_OK
end
BPF.flow_dissector :p
# want: SB014 5:23
