require "bpf"

# P026 E111: kretprobe — do_sys_poll の戻り値 (int — 自分の poll(NULL, n, 0) は n = 0 で 0、n > 0 で −14 (−EFAULT)) を
# Filter の tgid のときだけ Rets[0] (最後の値)・Rets[1] (回数)・Rets[2] (和) に (bpf-mlir E397 と同じ形)
Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Rets = BPF::ArrayMap.new("Rets", :i64, 3)

def on_ret_poll(ctx)
  tgid = BPF.pid_tgid >> 32
  f = Filter.lookup(0)
  if f
    if f.load == tgid
      r = ctx.ret
      Rets.update(0, r)
      Rets.atomic_add(1, 1)
      Rets.atomic_add(2, r)
    end
  end
end
BPF.kretprobe :on_ret_poll, "do_sys_poll", ret: :i32
