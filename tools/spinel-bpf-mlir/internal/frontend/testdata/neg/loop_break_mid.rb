require "bpf"

Out = BPF::ArrayMap.new("Out", :i64, 4)

# P015 E060: 腕の途中の break
def prog(ctx)
  s = 0
  4.times do |i|
    if i == 2
      break
      s += 100
    end
    s += i
  end
  Out.update(0, s)
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB030 10:7
