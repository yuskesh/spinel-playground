require "bpf"

# P029 E154: 3 段の埋め込みの経路 (bpf-mlir E553 の上限) — 合成の kernel の struct (e154_outer > e154_mid > e154_inner)。compile と schema-check
# まで (kernel にこの型は無い — attach しない、load の前の kfield の照合が止める)。t.load.mid.inner.v を Out[0] に
Inner = Struct.new(:v)
BPF.kernel_type(Inner, "e154_inner", v: :u32)
Mid = Struct.new(:inner)
BPF.kernel_type(Mid, "e154_mid", inner: [:struct, Inner])
Outer = Struct.new(:mid)
BPF.kernel_type(Outer, "e154_outer", mid: [:struct, Mid])
OuterT = BPF::KernelType.new(Outer.new(Mid.new(Inner.new(0))))

Out = BPF::ArrayMap.new("Out", :i64, 1)

def on_x(ctx)
  o = ctx.kptr_or_null(0, OuterT)
  if o
    Out.update(0, o.load.mid.inner.v)
  end
end
BPF.fentry :on_x, "tcp_sendmsg", args: {0 => [:or_null, OuterT]}
