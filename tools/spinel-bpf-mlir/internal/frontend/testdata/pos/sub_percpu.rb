require "bpf"

# P023 E092: 関数を跨ぐ RMW の形 (呼び手の lookup の読みを引数で callee へ・callee が同じ map を update) は per-CPU の map なら受理 (P009 の免除 — call site の map で)

P = BPF::PerCpuArrayMap.new("P", :u64, 4)
def put(v)
  P.update(1, v & 0xFFFF)
  0
end
def prog(ctx)
  p = P.lookup(0)
  if p
    put(p.load & 0xFF)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
