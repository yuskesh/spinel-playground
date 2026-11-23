require "bpf"

# P029 E158: uprobe の user の buffer (:user_buf) — target/pfix の put_buf(const void *buf, int len) の buf の先頭 64 byte を R.output_buf で
# (bpf-mlir の user.read — n = max(0, min(len, 64))、data 全体をゼロ化してから n byte、status は probe_read_user の生の値、count は n)。
W = Struct.new(:pid_tgid, :status, :count, :len, :data)
BPF.record(W, pid_tgid: :u64, status: :i64, count: :i32, len: :i32, data: [:u8, 64])
Writes = BPF::RingBuf.new("Writes", W.new(0, 0, 0, 0, Array.new(64, 0)), 65536)
Out = BPF::ArrayMap.new("Out", :i64, 2)

def on_put(ctx)
  r = Writes.output_buf(W.new(BPF.pid_tgid, 0, 0, ctx.arg(2), Array.new(64, 0)), :data, ctx.buf_arg(1), ctx.arg(2), :status, :status)
  if r
    Out.atomic_add(0, 1)
  else
    Out.atomic_add(1, 1)
  end
end
BPF.uprobe :on_put, "target/pfix", "put_buf", params: {1 => :user_buf, 2 => :i32}
# want: SB024 11:126
