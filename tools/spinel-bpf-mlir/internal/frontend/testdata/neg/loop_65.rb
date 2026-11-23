require "bpf"

Out = BPF::ArrayMap.new("Out", :i64, 4)

# P015 E060: literal の回数が 64 を超える
def prog(ctx)
  s = 0
  65.times { |i| s += i }
  Out.update(0, s)
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB030 8:3
