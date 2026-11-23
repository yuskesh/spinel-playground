require "bpf"

# E088 (P021): tp_btf の sched_process_fork — pointer の field の辿り。親の tgid が Cfg[0] で子が process (pid == tgid — thread の clone を数えない) の
# fork を数え、子の real_parent の tgid・vfork_done が NULL の回・mm の在る回を Out に (差動は試験の知る値 — real_parent は harness (自分)、
# fork(2) の子の vfork_done は NULL (go-bpf-mlir E136)、mm は在る)。
Mm = Struct.new(:total_vm)
BPF.kernel_type(Mm, "mm_struct", total_vm: :u64)
MmT = BPF::KernelType.new(Mm.new(0))
Completion = Struct.new(:done)
BPF.kernel_type(Completion, "completion", done: :u32)
CompletionT = BPF::KernelType.new(Completion.new(0))
Task = Struct.new(:pid, :tgid, :real_parent, :mm, :vfork_done)
BPF.kernel_type(Task, "task_struct", pid: :i32, tgid: :i32, real_parent: [:kptr, Task], mm: [:kptr, Mm], vfork_done: [:kptr, Completion])
TaskT = BPF::KernelType.new(Task.new(0, 0, 0, 0, 0))
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Out = BPF::ArrayMap.new("Out", :u64, 4)

def on_fork(ctx)
  parent = ctx.kptr(0, TaskT)
  child = ctx.kptr(1, TaskT)
  c = Cfg.lookup(0)
  if c
    if parent.load.tgid == c.load && child.load.pid == child.load.tgid
      Out.atomic_add(0, 1)
      rp = child.ptr(:real_parent, TaskT)
      if rp
        Out.update(1, rp.load.tgid & 0xFFFFFFFF)
      end
      vd = child.ptr(:vfork_done, CompletionT)
      if vd
        Out.update(2, 1000000)
      else
        Out.atomic_add(2, 1)
      end
      mm = child.ptr(:mm, MmT)
      if mm
        Out.atomic_add(3, 1)
      end
    end
  end
end
BPF.tp_btf :on_fork, "sched_process_fork", args: {0 => TaskT, 1 => TaskT}
