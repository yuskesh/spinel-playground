require "bpf"

# E095 (レビュー役の足し): per-CPU の hash の同じ形 (呼び手の読み → 整数の引数 → helper の借用の atomic_add) は受理 (P009 の免除 — xdp だけの program)
H = BPF::PerCpuHashMap.new("H", :u32, :u64, 16)

def bump(q, d)
  q.atomic_add(d & 0xFF)
  0
end

def prog(ctx)
  p = H.lookup(1)
  if p
    v = p.load & 0xFF
    bump(p, v)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
