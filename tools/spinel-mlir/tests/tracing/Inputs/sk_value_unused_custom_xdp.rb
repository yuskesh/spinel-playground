require "bpf"

Socks = BPF::SockMap.new("Socks", :u32, 2)

def pick(ctx)
  BPF::XDP_PASS
end
BPF.xdp :pick
# want: SB013 3:35
