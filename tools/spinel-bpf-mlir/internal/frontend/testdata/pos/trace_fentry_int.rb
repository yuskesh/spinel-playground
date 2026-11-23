require "bpf"

# P026 E117: fentry の整数の引数 — bpf_fentry_test6(u64 a, void *b, short c, int d, void *e, u64 f) (kernel の tracing の test run が
# (16, 17, 18, 19, 20, 21) で呼ぶ)。void * の 1・4 は宣言しない。Filter の tgid のとき Out[0] に 1 を足し・Out[1] = a の下位 32 bit・
# Out[2] = c・Out[3] = d・Out[4] に f の下位 32 bit を足す (符号と幅は load の前に farg で FUNC_PROTO と照合 — bpf-mlir E530)
Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 5)

def on_t6(ctx)
  tgid = BPF.pid_tgid >> 32
  f = Filter.lookup(0)
  if f
    if f.load == tgid
      Out.atomic_add(0, 1)
      Out.update(1, ctx.arg(0) & 0xFFFF_FFFF)
      Out.update(2, ctx.arg(2))
      Out.update(3, ctx.arg(3))
      Out.atomic_add(4, ctx.arg(5) & 0xFFFF_FFFF)
    end
  end
end
BPF.fentry :on_t6, "bpf_fentry_test6", args: {0 => :u64, 2 => :i16, 3 => :i32, 5 => :u64}
