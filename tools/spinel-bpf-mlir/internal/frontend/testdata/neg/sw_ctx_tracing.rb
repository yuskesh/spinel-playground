require "bpf"

# E095 (P023 段 3): 前の sp_ctx_arg.rb (xdp の ctx を helper に — 段 1 の SB034) は段 3 で受理になった。tracing の kind の ctx を helper に渡す形 (attach に
# 依る読み — bpf-mlir R051) の SB034 に改めた
Out = BPF::ArrayMap.new("Out", :u64, 4)

def f(c)
  1
end

def on_t(ctx)
  Out.update(0, f(ctx) & 0xFF)
end
BPF.fentry :on_t, "bpf_fentry_test1"
# want: SB034 7:1
