require "bpf"

# P026 E114: tracepoint — syscalls/sys_enter_write の __syscall_nr・fd・count (offset と型は 7.1.8 の tracefs の format — load の前に照合)。
# Filter の tgid かつ fd の下位 32 bit が 900 のときだけ Out[0] に 1 を足し・Out[1] = __syscall_nr・Out[2] に count の下位 32 bit を足す
# (bpf-mlir E427 の g14_tpw と同じ形 — 自分の stdout / stderr の write は fd で、他の process は tgid で除く)
Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 3)

def on_write(ctx)
  tgid = BPF.pid_tgid >> 32
  f = Filter.lookup(0)
  if f
    if f.load == tgid
      if (ctx.field(:fd) & 0xFFFF_FFFF) == 900
        Out.atomic_add(0, 1)
        Out.update(1, ctx.field(:__syscall_nr))
        Out.atomic_add(2, ctx.field(:count) & 0xFFFF_FFFF)
      end
    end
  end
end
BPF.tracepoint :on_write, "syscalls/sys_enter_write", fields: {__syscall_nr: [8, :i32], fd: [16, :u64], count: [32, :u64]}
