require "bpf"

Out = BPF::ArrayMap.new("Out", :i64, 4)

# P015 E060: block の局所を loop の後で読む
def prog(ctx)
  4.times do |i|
    t = i * 2
  end
  Out.update(0, t)
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB030 10:17
