require "bpf"

# P026 E123: XDP の adjust_tail (縮める側だけ) — status を Out[0] に、縮めた後に 18 byte の窓が入れば Out[1] に 1。delta 0 の program も (helper は呼ばれる)
Out = BPF::ArrayMap.new("Out", :i64, 2)

def trim4(ctx)
  st = ctx.adjust_tail(-4)
  Out.update(0, st)
  w = ctx.check(0, 18)
  if w
    Out.update(1, 1)
  end
  BPF::XDP_PASS
end

def trim0(ctx)
  _ = ctx.adjust_tail(0)
  BPF::XDP_PASS
end
BPF.xdp :trim4
BPF.xdp :trim0
