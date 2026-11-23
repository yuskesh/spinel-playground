require "bpf"

# P026 E130: 添字の無い field (ipv4_src) に添字
def p(ctx)
  ctx.set_key(:ipv4_src, 1, 2)
  BPF::FLOW_OK
end
BPF.flow_dissector :p
# want: SB002 5:3
