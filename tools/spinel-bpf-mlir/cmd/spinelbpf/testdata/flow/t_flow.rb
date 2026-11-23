require "bpf"

# E130 H5: flow_dissector の差動の表 — flow4 / flow6 (pos/flow_basic と同じ本体) と、nhoff を 0・thoff を 65535 に書く clamp (kernel が nhoff を [14, n]、thoff を [nhoff, n] に clamp)
def flow4(ctx)
  w = ctx.check(14, 20)
  if w
    ctx.set_key(:addr_proto, 0x0800)
    ctx.set_key(:ip_proto, w.u8(9))
    ctx.set_key(:ipv4_src, w.le32(12))
    ctx.set_key(:ipv4_dst, w.le32(16))
    ctx.set_key(:thoff, (ctx.key(:nhoff) + 20) & 0xFFFF)
  end
  return BPF::FLOW_DROP if ctx.key(:n_proto) != 8
  BPF::FLOW_OK
end

def flow6(ctx)
  w = ctx.check(14, 40)
  if w
    ctx.set_key(:ip_proto, w.u8(6))
    ctx.set_key(:ipv6_src, 2, w.le32(16))
    ctx.set_key(:ipv6_dst, 3, w.le32(36))
  end
  BPF::FLOW_OK
end

def clamp(ctx)
  ctx.set_key(:nhoff, 0)
  ctx.set_key(:thoff, 65535)
  BPF::FLOW_CONTINUE
end
BPF.flow_dissector :flow4
BPF.flow_dissector :flow6
BPF.flow_dissector :clamp
