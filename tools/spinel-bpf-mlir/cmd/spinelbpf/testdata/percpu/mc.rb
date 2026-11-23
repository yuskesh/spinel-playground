require "bpf"

# E039 H1: per-CPU の多 CPU — record の member の += (atomic 無し) と per-CPU の hash の add_or_init。CPU ごとの slot = その CPU の thread の実行の数
S = Struct.new(:n, :m)
BPF.record(S, n: :u64, m: :u64)
P = BPF::PerCpuRecordMap.new("P", S.new(0, 0), 1)
H = BPF::PerCpuHashMap.new("H", :u32, :u64, 8)

def prog(ctx)
  p = P.lookup(0)
  if p
    p.load.n += 1
    p.load.m += 2
  end
  _ = H.add_or_init(3, 1)
  BPF::XDP_PASS
end
BPF.xdp :prog
