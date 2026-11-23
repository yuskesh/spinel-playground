require "bpf"

Out = BPF::ArrayMap.new("Out", :i64, 4)

# P015 E060: loop の外の lookup の present の値を本体で読む
def prog(ctx)
  p = Out.lookup(1)
  if p
    s = 0
    4.times { |i| s += p.load }
    Out.update(0, s)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB030 10:24
