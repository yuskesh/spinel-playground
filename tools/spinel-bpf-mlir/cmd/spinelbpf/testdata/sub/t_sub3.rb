require "bpf"

# E095 (P023 段 3): 同じ packet の解析を inline に書いた program と窓の helper・context の helper を呼ぶ program — xdp (Out[0..3]) と
# sched_cls (Out[4..7])。双子 = kernel と inline = helper の差動。
Out = BPF::ArrayMap.new("Out", :u64, 8)

def etype(w)
  w.be16(12)
end

def ip_proto(ctx)
  r = 0
  w = ctx.check(0, 34)
  if w
    if w.be16(12) == 0x0800
      r = w.u8(23)
    end
  end
  r
end

def x_inline(ctx)
  w = ctx.check(0, 14)
  if w
    Out.update(0, w.be16(12))
  end
  r = 0
  v = ctx.check(0, 34)
  if v
    if v.be16(12) == 0x0800
      r = v.u8(23)
    end
  end
  Out.update(1, r)
  BPF::XDP_PASS
end
BPF.xdp :x_inline

def x_helper(ctx)
  w = ctx.check(0, 14)
  if w
    Out.update(2, etype(w) & 0xFFFF)
  end
  Out.update(3, ip_proto(ctx) & 0xFF)
  BPF::XDP_PASS
end
BPF.xdp :x_helper

def c_inline(ctx)
  w = ctx.check(0, 14)
  if w
    Out.update(4, w.be16(12))
  end
  BPF::TC_PASS
end
BPF.tcx :c_inline, :ingress

def c_helper(ctx)
  w = ctx.check(0, 14)
  if w
    Out.update(5, etype(w) & 0xFFFF)
  end
  BPF::TC_PASS
end
BPF.tcx :c_helper, :ingress
