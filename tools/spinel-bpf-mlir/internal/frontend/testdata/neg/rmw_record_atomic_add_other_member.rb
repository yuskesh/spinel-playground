require "bpf"

S = Struct.new(:a, :b)
BPF.record(S, a: :u32, b: :u32)
R = BPF::RecordMap.new("R", S.new(0, 0), 2)

# P015 E063 追記: record の member の atomic_add の delta が同じ entry の別の member の読み (entry の粒度で止める)
def prog(ctx)
  p = R.lookup(0)
  if p
    p.atomic_add(:a, p.load.b & 0xFF)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB019 11:5
