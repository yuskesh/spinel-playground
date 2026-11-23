require "bpf"

# P023 E094: 借用の helper を跨ぐ RMW の形 (呼び手の読みを整数の引数で helper へ・helper が借用の member に書く) は per-CPU の record の map なら受理 (P009 の免除 — call site の map で)

Stat = Struct.new(:hits, :last)
BPF.record(Stat, hits: :u64, last: :u64)
Stats = BPF::PerCpuRecordMap.new("Stats", Stat.new(0, 0), 4)
def setv(q, x)
  q.load.hits = x & 0xFFFF
  0
end

def prog(ctx)
  p = Stats.lookup(0)
  if p
    v = p.load.hits & 0xFF
    setv(p, v + 1)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
