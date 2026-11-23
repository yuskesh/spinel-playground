require "bpf"

# P015 E062 H3: record の map の同じ entry の read-modify-write の値に溢れる + 1 (u64 の member) — 直しの前は SB014 が RMW を隠した
S = Struct.new(:a, :b)
BPF.record(S, a: :u64, b: :u64)
R = BPF::RecordMap.new("R", S.new(0, 0), 2)

def prog(ctx)
  p = R.lookup(0)
  if p
    R.update(0, S.new(p.load.a + 1, 0))
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB019 11:5
