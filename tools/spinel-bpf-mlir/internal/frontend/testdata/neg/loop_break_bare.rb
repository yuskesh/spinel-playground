require "bpf"

Out = BPF::ArrayMap.new("Out", :i64, 4)

# P015 E060: 本体の直下の無条件の break (以降が死んだ code)
def prog(ctx)
  s = 0
  4.times do |i|
    s += i
    break
  end
  Out.update(0, s)
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB030 10:5
