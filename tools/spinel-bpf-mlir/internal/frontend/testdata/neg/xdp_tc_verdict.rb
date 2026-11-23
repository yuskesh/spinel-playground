require "bpf"

# P019 E076: xdp の program が sched_cls の判定を返す
def p(ctx)
  BPF::TC_PASS
end
BPF.xdp :p
# want: SB028 5:3
