require "bpf"

# E151 (P028) の H5: execve の第 1 引数 filename (const char * — 深度 1) を :user_str_array と宣言 — compile は通り、load の前の sysarg … strarray の
# 照合 (char pointer 深度 2 — bpf-mlir E548) が止める。
Ev = Struct.new(:index, :pad, :arg, :status)
BPF.record(Ev, index: :u32, pad: :u32, arg: [:u8, 16], status: :i64)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, Array.new(16, 0), 0), 65536)

def on_bad(ctx)
  _ = Events.output_argv(Ev.new(0, 0, Array.new(16, 0), 0), :arg, ctx.argv_arg(1), :status, :index)
end
BPF.ksyscall :on_bad, "execve", params: {1 => :user_str_array}

require "spinelbpf"

begin
  obj = SpinelBPF.load_embedded
  puts "load kind=OK"
  obj.close
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
end
