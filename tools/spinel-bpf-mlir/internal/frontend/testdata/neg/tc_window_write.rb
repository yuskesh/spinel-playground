require "bpf"

# P019 E076: window への書き (API に無い — xdp_window_write.rb と同じ診断)
def p(skb)
  w = skb.check(0, 14)
  if w
    w.set_u8(0, 1)
  end
  BPF::TC_PASS
end
BPF.tcx :p, :ingress
# want: SB002 7:5
