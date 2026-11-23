require "bpf"

# P017 後 E073: 早い return — program の直下の guard (return BPF::XDP_DROP if / unless) — 後ろの文は否定の条件で狭めて解析 (k ∈ [0, 7])
Hist = Struct.new(:hist, :n)
BPF.record(Hist, hist: [:u32, 8], n: :u64)
Hs = BPF::RecordMap.new("Hs", Hist.new(Array.new(8, 0), 0), 1)
In = BPF::ArrayMap.new("In", :i32, 1)
Out = BPF::ArrayMap.new("Out", :u64, 4)

def prog(ctx)
  k = 0
  q = In.lookup(0)
  if q
    k = q.load
  end
  return BPF::XDP_DROP if k < 0
  Out.update(0, 1)
  return BPF::XDP_DROP unless k < 8
  p = Hs.lookup(0)
  if p
    Out.update(1, p.load.hist[k])
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
