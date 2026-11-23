require "bpf"

# P017 後 E073: 早い return の判定が 2 つ (DROP と TX) — verdict.if は 2 つの判定だけ (最後の PASS と合わせて 3 つ)
In = BPF::ArrayMap.new("In", :i32, 1)
Out = BPF::ArrayMap.new("Out", :u64, 2)

def prog(ctx)
  k = 0
  q = In.lookup(0)
  if q
    k = q.load
  end
  return BPF::XDP_DROP if k < 0
  return BPF::XDP_TX if k > 100
  Out.update(0, 1)
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB008 14:3
