require "bpf"

S = Struct.new(:a, :b)
BPF.record(S, a: :u32, b: :u32)
R = BPF::RecordMap.new("R", S.new(0, 0), 2)

# P015 E063 追記: record の member の atomic_add の delta が同じ entry の出自の局所
def prog(ctx)
  p = R.lookup(0)
  if p
    x = p.load.a & 0xFF
    p.atomic_add(:a, x)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB019 12:5
