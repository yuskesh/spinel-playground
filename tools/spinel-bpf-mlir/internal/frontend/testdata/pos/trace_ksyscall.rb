require "bpf"

# P026 E115: ksyscall — prctl の syscall の引数 1〜5 (7.1.8 の tracefs の sys_enter_prctl — int option・unsigned long arg2〜arg5、
# load の前に照合)。Filter の tgid かつ option が 0x4511_5000 (知らない option — prctl は EINVAL を返すだけ) のときだけ
# Out[0] に 1 を足し・Out[1] = arg2・Out[2] = arg3・Out[3] = arg4 (syscall の規約の r10 — 関数の規約の cx ではない)・Out[4] に arg5 の下位 16 bit を足す
Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Out = BPF::ArrayMap.new("Out", :u64, 5)

def on_prctl(ctx)
  tgid = BPF.pid_tgid >> 32
  f = Filter.lookup(0)
  if f
    if f.load == tgid
      if ctx.arg(1) == 0x4511_5000
        Out.atomic_add(0, 1)
        Out.update(1, ctx.arg(2))
        Out.update(2, ctx.arg(3))
        Out.update(3, ctx.arg(4))
        Out.atomic_add(4, ctx.arg(5) & 0xFFFF)
      end
    end
  end
end
BPF.ksyscall :on_prctl, "prctl", params: {1 => :i32, 2 => :u64, 3 => :u64, 4 => :u64, 5 => :u64}
