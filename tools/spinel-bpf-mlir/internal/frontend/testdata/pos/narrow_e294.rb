require "bpf"

# P017 E071: bpf-mlir の E294 の形 — 利用者の if が添字を要素の数 (8) より小さい閾値 (5) で比べ、腕で helper (map の操作) を呼んでから同じ添字の ref.index。
# 警告は出ない (LLVM の分岐の消しに依る — bpf-mlir は文書だけ)。root の loader は受理、非 root の loader は拒否されうる (この repo は root の host だけで試す)
Hist = Struct.new(:hist, :n)
BPF.record(Hist, hist: [:u32, 8], n: :u64)
Hs = BPF::RecordMap.new("Hs", Hist.new(Array.new(8, 0), 0), 1)
In = BPF::ArrayMap.new("In", :i32, 1)
Out = BPF::ArrayMap.new("Out", :u64, 2)

def prog(ctx)
  q = In.lookup(0)
  if q
    i = q.load
    if i >= 0 && i < 5
      Out.update(1, 1)
      p = Hs.lookup(0)
      if p
        Out.update(0, p.load.hist[i])
      end
    end
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
