require "bpf"

# E118 (P026) の H5: linux_binprm の argc (int) を :strptr (char *) と宣言して読む — compile は通り、load の前の kfield strptr の照合 (target の BTF) が止める。
Bprm = Struct.new(:argc)
BPF.kernel_type(Bprm, "linux_binprm", argc: :strptr)
BprmT = BPF::KernelType.new(Bprm.new(""))

Ev = Struct.new(:name, :st)
BPF.record(Ev, name: [:u8, 32], st: :i64)
Events = BPF::RingBuf.new("Events", Ev.new(Array.new(32, 0), 0), 4096)

def on_bad(ctx)
  q = ctx.kptr_or_null(0, BprmT)
  if q
    _ = Events.output_str(Ev.new(Array.new(32, 0), 0), :name, q.str(:argc), :st)
  end
end
BPF.fentry :on_bad, "security_bprm_check", args: {0 => [:or_null, BprmT]}

require "spinelbpf"

begin
  obj = SpinelBPF.load_embedded
  puts "load kind=OK"
  obj.close
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
end
