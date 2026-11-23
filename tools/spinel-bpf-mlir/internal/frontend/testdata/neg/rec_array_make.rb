require "bpf"

# P016 E066: 配列の member を持つ record の record.make (Hist.new — E066 では受けない)
Hist = Struct.new(:hist, :n)
BPF.record(Hist, hist: [:u32, 8], n: :u64)
Hs = BPF::RecordMap.new("Hs", Hist.new(Array.new(8, 0), 0), 4)

def prog(ctx)
  Hs.update(0, Hist.new(Array.new(8, 0), 1))
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB024 9:16
