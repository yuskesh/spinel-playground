require "bpf"

# E073 で見つけた: 最後の文の値の無い return — 前は frontend が nil を読んで panic した (P001 からの既存)、今は SB008

Out = BPF::ArrayMap.new("Out", :u64, 1)

def prog(ctx)
  Out.update(0, 1)
  return
end
BPF.xdp :prog
# want: SB008 9:3
