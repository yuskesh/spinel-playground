require "bpf"
S = Struct.new(:n, :m)
BPF.record(S, n: :u64, m: :u64)
M = BPF::PerCpuRecordMap.new("M", S.new(0, 0), 2)
def prog(ctx)
  p = M.lookup(0)
  if p
    delta = p.load.m & 255
    p.load.n -= delta
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
