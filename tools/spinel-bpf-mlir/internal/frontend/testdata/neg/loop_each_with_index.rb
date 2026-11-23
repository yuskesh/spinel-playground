require "bpf"

Out = BPF::ArrayMap.new("Out", :i64, 4)

# P015 E060: each_with_index (Spinel が builtins を継ぎ込む — E056 の補正の後の位置)
def prog(ctx)
  s = 0
  (0...4).each_with_index { |a, i| s += i }
  Out.update(0, s)
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB030 8:3
