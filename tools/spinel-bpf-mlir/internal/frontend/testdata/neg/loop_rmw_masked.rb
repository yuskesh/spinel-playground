require "bpf"

Out = BPF::ArrayMap.new("Out", :u64, 8)
H = BPF::HashMap.new("H", :u32, :u64, 16)

# P015 E061 (事後に足した — loop_rmw の意図): 範囲に収まる値の同じ map の read-modify-write は loop の本体でも SB019
def prog(ctx)
  4.times do |i|
    p = Out.lookup(i)
    if p
      Out.update(i, p.load & 0xFF)
    end
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB019 11:7
