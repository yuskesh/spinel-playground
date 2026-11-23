require "bpf"

# E123 H4: adjust_tail の差動の表 — delta 0 / −4 / −46 の 3 つの program、status を Out[k] に、縮めた後に 14 byte の窓の末尾の byte (13) を Out[k + 3] に
Out = BPF::ArrayMap.new("Out", :i64, 6)

def t0(ctx)
  st = ctx.adjust_tail(0)
  Out.update(0, st)
  w = ctx.check(0, 14)
  if w
    Out.update(3, w.u8(13))
  end
  BPF::XDP_PASS
end

def t4(ctx)
  st = ctx.adjust_tail(-4)
  Out.update(1, st)
  w = ctx.check(0, 14)
  if w
    Out.update(4, w.u8(13))
  end
  BPF::XDP_PASS
end

def t46(ctx)
  st = ctx.adjust_tail(-46)
  Out.update(2, st)
  w = ctx.check(0, 14)
  if w
    Out.update(5, w.u8(13))
  end
  BPF::XDP_PASS
end
BPF.xdp :t0
BPF.xdp :t4
BPF.xdp :t46
