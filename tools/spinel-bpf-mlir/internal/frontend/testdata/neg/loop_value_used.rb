require "bpf"

Out = BPF::ArrayMap.new("Out", :i64, 4)

# P015 E060: times の値を使う (receiver か break の値 — Spinel は poly)
def prog(ctx)
  s = 0
  r = 4.times do |i|
    break if i == 2
    s += i
  end
  Out.update(0, s)
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB030 8:7
