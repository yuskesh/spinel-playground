require "bpf"

# E089 (P021): tp_btf の sched_process_fork — 配列の field の写し。親の tgid が Cfg[0] で子が process (pid == tgid) の fork を Out[0] に数え、
# 子の comm (16 byte — 固定の写し) と pid を Recs[0] に (差動は試験の知る値 — harness が prctl で置いた comm (fork の子は親の comm を写す))。
Task = Struct.new(:pid, :tgid, :comm)
BPF.kernel_type(Task, "task_struct", pid: :i32, tgid: :i32, comm: [:u8, 16])
TaskT = BPF::KernelType.new(Task.new(0, 0, Array.new(16, 0)))
Ev = Struct.new(:comm, :pid)
BPF.record(Ev, comm: [:u8, 16], pid: :u32)
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Out = BPF::ArrayMap.new("Out", :u64, 1)
Recs = BPF::RecordMap.new("Recs", Ev.new(Array.new(16, 0), 0), 1)

def on_fork(ctx)
  parent = ctx.kptr(0, TaskT)
  child = ctx.kptr(1, TaskT)
  c = Cfg.lookup(0)
  if c
    if parent.load.tgid == c.load && child.load.pid == child.load.tgid
      Out.atomic_add(0, 1)
      r = Recs.lookup(0)
      if r
        r.load.comm = child.copy(:comm)
        r.load.pid = child.load.pid & 0xFFFFFFFF
      end
    end
  end
end
BPF.tp_btf :on_fork, "sched_process_fork", args: {0 => TaskT, 1 => TaskT}
