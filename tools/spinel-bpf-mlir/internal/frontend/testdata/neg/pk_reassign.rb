require "bpf"

Out = BPF::ArrayMap.new("Out", :u64, 4)

def prog(ctx)
  w = ctx.check(0, 14)
  if w
    Out.update(0, w.u8(0))
  end
  w = 1
  BPF::XDP_PASS
end
BPF.xdp :prog
# 再代入で Spinel は w を untyped (Window と Integer) にする — 束縛の行 (6:3) で「Window でない」SB005、注入の無い側の Integer との差を比較器が SB010 で (E014)
# want: SB005 6:3
