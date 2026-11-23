require "bpf"

# P019 E076: 判定で終わらない sched_cls の program
Counts = BPF::ArrayMap.new("Counts", :u64, 2)

def p(skb)
  Counts.atomic_add(0, 1)
end
BPF.tcx :p, :ingress
# want: SB008 7:3
