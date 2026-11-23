require "bpf"

# E143 (P028) の H5: openat の第 3 引数 flags (int) を :user_str と宣言して読む — compile は通り、load の前の sysarg … strptr の照合
# (tracefs の char pointer 深度 1 — bpf-mlir E547) が止める。
Ev = Struct.new(:name, :status)
BPF.record(Ev, name: [:u8, 16], status: :i64)
Events = BPF::RingBuf.new("Events", Ev.new(Array.new(16, 0), 0), 4096)

def on_bad(ctx)
  _ = Events.output_str(Ev.new(Array.new(16, 0), 0), :name, ctx.str_arg(3), :status)
end
BPF.ksyscall :on_bad, "openat", params: {3 => :user_str}

require "spinelbpf"

begin
  obj = SpinelBPF.load_embedded
  puts "load kind=OK"
  obj.close
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
end
