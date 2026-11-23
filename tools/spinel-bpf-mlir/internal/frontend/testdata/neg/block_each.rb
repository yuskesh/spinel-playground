require "bpf"

Counts = BPF::ArrayMap.new("Counts", :u64, 2)

def prog(ctx)
  [1].each { |x| x }
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB030 6:3
# (E060 で SB002 → SB030: block 付きの each は P015 の loop の形の検査が先に名指しする — 位置は同じ)
