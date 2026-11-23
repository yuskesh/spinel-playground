require "bpf"

# P026 E113: raw_tp — sys_enter の args[1] (syscall の番号) と args[0] (struct pt_regs * の raw の値) を、Filter の tgid のときだけ:
# 番号の下位 32 bit が 110 (getppid) なら Seen[0] に 1 を足し、1_000_000 以上 (実の syscall に無い番号 — test run の合成だけ) なら
# Seen[1] = args[1] (u64 を直に)・Seen[2] = args[0] の下位 32 bit・Seen[3] に args[0] の上位 32 bit を足す (bpf-mlir E396 と同じ args)
Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Seen = BPF::ArrayMap.new("Seen", :u64, 4)

def on_sys_enter(ctx)
  tgid = BPF.pid_tgid >> 32
  f = Filter.lookup(0)
  if f
    if f.load == tgid
      nr = ctx.arg(1) & 0xFFFF_FFFF
      if nr == 110
        Seen.atomic_add(0, 1)
      elsif nr >= 1_000_000
        Seen.update(1, ctx.arg(1))
        Seen.update(2, ctx.arg(0) & 0xFFFF_FFFF)
        Seen.atomic_add(3, ctx.arg(0) >> 32)
      end
    end
  end
end
BPF.raw_tp :on_sys_enter, "sys_enter"
