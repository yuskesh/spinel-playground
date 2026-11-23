require "bpf"

# E087 (P021): tp_btf の sched_process_fork — 親の tgid が Cfg[0] の fork を数え、最後の子の pid・tgid を Out に (差動は試験が知る値 — 親の
# tgid (自分)・子の pid (fork の戻り値)・子の tgid (単一 thread の子は pid と同じ))。
Task = Struct.new(:pid, :tgid)
BPF.kernel_type(Task, "task_struct", pid: :i32, tgid: :i32)
TaskT = BPF::KernelType.new(Task.new(0, 0))
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Out = BPF::ArrayMap.new("Out", :u64, 3)

def on_fork(ctx)
  parent = ctx.kptr(0, TaskT)
  child = ctx.kptr(1, TaskT)
  c = Cfg.lookup(0)
  if c
    if parent.load.tgid == c.load
      Out.atomic_add(0, 1)
      Out.update(1, child.load.pid & 0xFFFFFFFF)
      Out.update(2, child.load.tgid & 0xFFFFFFFF)
    end
  end
end
BPF.tp_btf :on_fork, "sched_process_fork", args: {0 => TaskT, 1 => TaskT}
