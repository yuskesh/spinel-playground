require "bpf"

# P021 E086: tp_btf の sched_switch(bool preempt, struct task_struct *prev, struct task_struct *next, unsigned int prev_state) — 整数の引数
# preempt (u8)・prev_state (u32) と struct の引数 next の pid。引数 1 (prev) は読まない (schema の args は null)。
Task = Struct.new(:pid)
BPF.kernel_type(Task, "task_struct", pid: :i32)
TaskT = BPF::KernelType.new(Task.new(0))

Seen = BPF::ArrayMap.new("Seen", :u64, 3)

def on_switch(ctx)
  nxt = ctx.kptr(2, TaskT)
  Seen.atomic_add(0, ctx.arg(0))
  Seen.update(1, ctx.arg(3) & 0xFFFFFFFF)
  Seen.update(2, nxt.load.pid & 0xFFFFFFFF)
end
BPF.tp_btf :on_switch, "sched_switch", args: {0 => :u8, 2 => TaskT, 3 => :u32}
