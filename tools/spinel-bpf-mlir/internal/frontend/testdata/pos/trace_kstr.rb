require "bpf"

# P026 E118: kernel の struct の char * の member の先の文字列 — fentry/security_bprm_check の linux_binprm の filename (execve に渡した path)。
# Filter の tgid (harness が fork した子の pid) の exec だけ、Events に {name: filename の先頭 31 byte と NUL, st: probe_read_kernel_str の status}
Bprm = Struct.new(:filename)
BPF.kernel_type(Bprm, "linux_binprm", filename: :strptr)
BprmT = BPF::KernelType.new(Bprm.new(""))

Ev = Struct.new(:name, :st)
BPF.record(Ev, name: [:u8, 32], st: :i64)
Events = BPF::RingBuf.new("Events", Ev.new(Array.new(32, 0), 0), 4096)
Filter = BPF::ArrayMap.new("Filter", :u32, 1)

def on_exec(ctx)
  q = ctx.kptr_or_null(0, BprmT)
  if q
    tgid = BPF.pid_tgid >> 32
    f = Filter.lookup(0)
    if f
      if f.load == tgid
        _ = Events.output_str(Ev.new(Array.new(32, 0), 0), :name, q.str(:filename), :st)
      end
    end
  end
end
BPF.fentry :on_exec, "security_bprm_check", args: {0 => [:or_null, BprmT]}
