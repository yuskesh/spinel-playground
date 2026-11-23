require "bpf"

# P028 E144: fmod_ret — bpf_modify_return_test(int a, int *b) (kernel の tracing の test run が (1, &b) で呼ぶ — b は 2、元の関数は
# *b += 1 で a + *b = 4 を返す)。戻り値は名前付きだけ: BPF::FMOD_CALL (元の関数) と BPF.fmod_return(e) (e は区間で 0 を含まない)。
# on_guard: Filter の tgid のとき Out[0] に a を足し、Cfg[0] が 1 なら −1 に差し替え、他は元の関数。on_val: (a & 0xFF) + 1 (区間 [1, 256]) に差し替え。
# on_obs (fexit): trampoline の後の戻り値を Out[3] に、観測の数を Out[2] に (bml の test run は retval を返さない — E144 追補 1)
Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 4)

def on_guard(ctx)
  tgid = BPF.pid_tgid >> 32
  f = Filter.lookup(0)
  if f
    if f.load == tgid
      Out.atomic_add(0, ctx.arg(0))
    end
  end
  m = 0
  c = Cfg.lookup(0)
  if c
    m = c.load
  end
  return BPF.fmod_return(-1) if m == 1
  BPF::FMOD_CALL
end
BPF.fmod_ret :on_guard, "bpf_modify_return_test", nargs: 2, args: {0 => :i32}

def on_val(ctx)
  BPF.fmod_return((ctx.arg(0) & 0xFF) + 1)
end
BPF.fmod_ret :on_val, "bpf_modify_return_test", nargs: 2, args: {0 => :i32}

def on_obs(ctx)
  tgid = BPF.pid_tgid >> 32
  f = Filter.lookup(0)
  if f
    if f.load == tgid
      Out.atomic_add(2, 1)
      Out.update(3, ctx.ret)
    end
  end
end
BPF.fexit :on_obs, "bpf_modify_return_test", nargs: 2, ret: :i32
