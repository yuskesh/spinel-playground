require "bpf"

Out = BPF::ArrayMap.new("Out", :i64, 4)

# P015 E060: block の引数の再代入
def prog(ctx)
  s = 0
  4.times do |i|
    i = 2
    s += i
  end
  Out.update(0, s)
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB030 9:5
