require "bpf"

# P026 E124: XDP の redirect_map — frame の先頭 byte の下位 2 bit を key に devmap Ports へ (entry が在れば XDP_REDIRECT、無ければ
# fallback の XDP_PASS)。窓が取れなければ key 3 (user の側が入れない限り fallback)。Ports の ifindex は user の側が map_put で入れる。
Ports = BPF::DevMap.new("Ports", :u32, 4)

def redir(ctx)
  k = 3
  w = ctx.check(0, 14)
  if w
    k = w.u8(0) & 3
  end
  Ports.redirect(k, BPF::XDP_PASS)
end
BPF.xdp :redir
