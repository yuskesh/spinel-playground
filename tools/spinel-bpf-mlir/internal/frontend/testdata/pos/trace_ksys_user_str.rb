require "bpf"

# P028 E143: ksyscall の user の文字列の引数 — openat(int dfd, const char *filename, int flags, umode_t mode) の filename (第 2 引数 — :user_str) を
# ctx.str_arg(2) で ring の event の name ([:u8, 32]) に読む (bpf-mlir E547 — ksyscall.arg -> !ebpf.user_str と user.read_str)、flags (第 3 引数) は整数。
# Filter の tgid のとき Events に {flags, name, status}、出せたら Out[0] に 1 を足す
Ev = Struct.new(:flags, :pad, :name, :status)
BPF.record(Ev, flags: :i32, pad: :u32, name: [:u8, 32], status: :i64)

Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 1)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, Array.new(32, 0), 0), 4096)

def on_open(ctx)
  tgid = BPF.pid_tgid >> 32
  f = Filter.lookup(0)
  if f
    if f.load == tgid
      r = Events.output_str(Ev.new(ctx.arg(3), 0, Array.new(32, 0), 0), :name, ctx.str_arg(2), :status)
      if r
        Out.atomic_add(0, 1)
      end
    end
  end
end
BPF.ksyscall :on_open, "openat", params: {2 => :user_str, 3 => :i32}
