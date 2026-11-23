require "bpf"

# E089 (P021): fentry の struct の引数 (常に nullable)。自分の tgid (Cfg[0]) の呼び出しだけ: bpf_fentry_test7 の arg (tracing の test run は NULL を
# 渡す) の在る / 無い回、bpf_fentry_test8 の arg (在る — `arg = {}`) の回とその a (NULL) の在る / 無い回、wake_up_new_task の p の在る回と最後の pid
# (p が process (pid == tgid) の時だけ — bml の tracing の test run は別の thread を作り、その thread も wake_up_new_task を通る)。
Task = Struct.new(:pid, :tgid)
BPF.kernel_type(Task, "task_struct", pid: :i32, tgid: :i32)
TaskT = BPF::KernelType.new(Task.new(0, 0))
FTest = Struct.new(:a)
BPF.kernel_type(FTest, "bpf_fentry_test_t", a: [:kptr, FTest])
FTestT = BPF::KernelType.new(FTest.new(0))
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Out = BPF::ArrayMap.new("Out", :u64, 8)

def on_t7(ctx)
  mine = 0
  c = Cfg.lookup(0)
  if c
    if BPF.pid_tgid >> 32 == c.load
      mine = 1
    end
  end
  t = ctx.kptr_or_null(0, FTestT)
  if t
    if mine == 1
      Out.atomic_add(0, 1)
    end
  else
    if mine == 1
      Out.atomic_add(1, 1)
    end
  end
end
BPF.fentry :on_t7, "bpf_fentry_test7", args: {0 => [:or_null, FTestT]}

def on_t8(ctx)
  mine = 0
  c = Cfg.lookup(0)
  if c
    if BPF.pid_tgid >> 32 == c.load
      mine = 1
    end
  end
  t = ctx.kptr_or_null(0, FTestT)
  if t
    if mine == 1
      Out.atomic_add(2, 1)
    end
    a = t.ptr(:a, FTestT)
    if a
      if mine == 1
        Out.atomic_add(3, 1)
      end
    else
      if mine == 1
        Out.atomic_add(4, 1)
      end
    end
  end
end
BPF.fentry :on_t8, "bpf_fentry_test8", args: {0 => [:or_null, FTestT]}

def on_wake(ctx)
  mine = 0
  c = Cfg.lookup(0)
  if c
    if BPF.pid_tgid >> 32 == c.load
      mine = 1
    end
  end
  p = ctx.kptr_or_null(0, TaskT)
  if p
    if mine == 1 && p.load.pid == p.load.tgid
      Out.atomic_add(5, 1)
      Out.update(6, p.load.pid & 0xFFFFFFFF)
    end
  else
    if mine == 1
      Out.atomic_add(7, 1)
    end
  end
end
BPF.fentry :on_wake, "wake_up_new_task", args: {0 => [:or_null, TaskT]}
