require "bpf"

# P028 E151: argv — ksyscall execve(const char *filename, const char *const *argv, …) の argv (第 2 引数 — :user_str_array) の slot 0..19 を
# R.output_argv で 1 つずつ ring の event に (bpf-mlir E548 — str_at の 20 段の present の入れ子に展開)。Filter の tgid (harness の子) のときだけ。
# 20 の event は「argv がちょうど 20」と「21 以上 (先頭 20 で打ち切り)」を区別しない
Ev = Struct.new(:index, :pad, :arg, :status)
BPF.record(Ev, index: :u32, pad: :u32, arg: [:u8, 32], status: :i64)

Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, Array.new(32, 0), 0), 65536)

def on_exec(ctx)
  tgid = BPF.pid_tgid >> 32
  f = Filter.lookup(0)
  if f
    if f.load == tgid
      _ = Events.output_argv(Ev.new(0, 0, Array.new(32, 0), 0), :arg, ctx.argv_arg(2), :status, :index)
    end
  end
end
BPF.ksyscall :on_exec, "execve", params: {2 => :user_str_array}
