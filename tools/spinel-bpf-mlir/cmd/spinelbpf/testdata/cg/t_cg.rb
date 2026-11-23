require "bpf"

# E127 H5: cgroup_skb の差動の表 — len を Out[0] に、IPv4 の protocol (window の offset 9 — packet は network header から) を Out[1] に、len > 64 で deny

Out = BPF::ArrayMap.new("Out", :u32, 2)

def small_in(skb)
  n = skb.len
  Out.update(0, n)
  pr = 0
  w = skb.check(0, 20)
  if w
    pr = w.u8(9)
  end
  Out.update(1, pr)
  return BPF::CG_DENY if n > 64
  BPF::CG_ALLOW
end

def small_out(skb)
  n = skb.len
  Out.update(0, n)
  pr = 0
  w = skb.check(0, 20)
  if w
    pr = w.u8(9)
  end
  Out.update(1, pr)
  return BPF::CG_DENY if n > 64
  BPF::CG_ALLOW
end
BPF.cgroup_skb :small_in, :ingress
BPF.cgroup_skb :small_out, :egress
