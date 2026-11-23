require "bpf"

# P026 E130: set_key を式の中に (文だけ)
def p(ctx)
  return BPF::FLOW_DROP if ctx.set_key(:thoff, 14) == 0
  BPF::FLOW_OK
end
BPF.flow_dissector :p
# want: SB002 5:28
