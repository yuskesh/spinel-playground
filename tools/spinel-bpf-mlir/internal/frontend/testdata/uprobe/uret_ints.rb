require "bpf"

# P026 E112: uretprobe — target/cfix の sum_args (int64_t を返す) と greet (uint32_t を返す) の戻り値を
# Rets[0] (sum の最後)・Rets[1] (sum の回数)・Rets[2] (sum の和)・Rets[3] (greet の最後)・Rets[4] (greet の回数) に
Rets = BPF::ArrayMap.new("Rets", :i64, 5)

def on_sum_ret(ctx)
  r = ctx.ret
  Rets.update(0, r)
  Rets.atomic_add(1, 1)
  Rets.atomic_add(2, r)
end
BPF.uretprobe :on_sum_ret, "target/cfix", "sum_args", ret: :i64

def on_greet_ret(ctx)
  Rets.update(3, ctx.ret)
  Rets.atomic_add(4, 1)
end
BPF.uretprobe :on_greet_ret, "target/cfix", "greet", ret: :u32
