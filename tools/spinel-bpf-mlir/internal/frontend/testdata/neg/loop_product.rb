require "bpf"

Out = BPF::ArrayMap.new("Out", :i64, 4)

# P015 E060: 入れ子の回数の積が 64 を超える (16 × 8)
def prog(ctx)
  s = 0
  16.times do |i|
    8.times { |j| s += i + j }
  end
  Out.update(0, s)
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB030 9:5
