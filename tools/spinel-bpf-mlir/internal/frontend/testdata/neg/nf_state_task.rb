require "bpf"

# P026 E128: ctx.state の T が nf_hook_state でない kernel の struct
Task = Struct.new(:pid)
BPF.kernel_type(Task, "task_struct", pid: :i32)
TaskT = BPF::KernelType.new(Task.new(0))
Out = BPF::ArrayMap.new("Out", :u32, 1)

def p(ctx)
  st = ctx.state(TaskT)
  Out.update(0, st.load.pid)
  BPF::NF_ACCEPT
end
BPF.netfilter :p
# want: SB033 10:18
