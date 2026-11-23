require "bpf"

# P016 E066 の負の例 → E068 で正の例: 可変の添字 i ∈ [0, 7] (受ける) — 既定の定数 0 と lookup の値が合流して同じ添字に届く (E254 の形 — ebpf-compile の E274 の warning、SB021 の Conditional)
Hist = Struct.new(:hist, :n)
BPF.record(Hist, hist: [:u32, 8], n: :u64)
Hs = BPF::RecordMap.new("Hs", Hist.new(Array.new(8, 0), 0), 4)
Out = BPF::ArrayMap.new("Out", :u64, 2)

def prog(ctx)
  i = 0
  q = Out.lookup(1)
  if q
    i = q.load & 7
  end
  p = Hs.lookup(0)
  if p
    Out.update(0, p.load.hist[i])
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
