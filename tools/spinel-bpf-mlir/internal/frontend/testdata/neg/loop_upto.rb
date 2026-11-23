require "bpf"

Out = BPF::ArrayMap.new("Out", :i64, 4)

# P015 E060: upto は受ける形の外
def prog(ctx)
  s = 0
  0.upto(3) { |i| s += i }
  Out.update(0, s)
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB030 8:3
