require "bpf"

Out = BPF::ArrayMap.new("Out", :u64, 8)
H = BPF::HashMap.new("H", :u32, :u64, 16)

# P015 E061: loop の本体の同じ map の read-modify-write (u64 の + 1) — E061 では値の式の SB014 が先に出た (理由の順の穴)、E062 で RMW を先に見て SB019
def prog(ctx)
  4.times do |i|
    p = Out.lookup(i)
    if p
      Out.update(i, p.load + 1)
    end
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB019 11:7
