require "bpf"

Out = BPF::ArrayMap.new("Out", :u64, 8)
H = BPF::HashMap.new("H", :u32, :u64, 16)

# P015 E061: loop の前に検査した窓を loop の本体で読む (窓は loop を跨げない)
def prog(ctx)
  w = ctx.check(14, 8)
  if w
    s = 0
    8.times { |i| s += w.u8(0) }
    Out.update(0, s)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB030 11:24
