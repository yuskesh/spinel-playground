require "bpf"

# P028 E142: tracepoint の user の文字列の field — syscalls/sys_enter_openat の filename (const char * — offset 24、8 byte) を
# ctx.str_field(:filename) で ring の event の name ([:u8, 32]) に読む (bpf-mlir E546 — tp.field -> !ebpf.user_str と user.read_str)。
# Filter の tgid のとき Events に {nr: __syscall_nr, name, status: read_str の生の status}、出せたら Out[0] に 1 を足す
Ev = Struct.new(:nr, :pad, :name, :status)
BPF.record(Ev, nr: :i32, pad: :u32, name: [:u8, 32], status: :i64)

Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 1)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, Array.new(32, 0), 0), 4096)

def on_open(ctx)
  tgid = BPF.pid_tgid >> 32
  f = Filter.lookup(0)
  if f
    if f.load == tgid
      r = Events.output_str(Ev.new(ctx.field(:__syscall_nr), 0, Array.new(32, 0), 0), :name, ctx.str_field(:filename), :status)
      if r
        Out.atomic_add(0, 1)
      end
    end
  end
end
BPF.tracepoint :on_open, "syscalls/sys_enter_openat", fields: {__syscall_nr: [8, :i32], filename: [24, :user_str]}
