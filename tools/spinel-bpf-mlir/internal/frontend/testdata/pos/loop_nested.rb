require "bpf"

# P015 E060: 2 段の入れ子 (N の積 64) — 内側の next は内側の loop に
Out = BPF::ArrayMap.new("Out", :i64, 1)

def prog(ctx)
  s = 0
  8.times do |i|
    8.times do |j|
      next if j > i
      s += i * j
    end
  end
  Out.update(0, s)
  BPF::XDP_PASS
end
BPF.xdp :prog
