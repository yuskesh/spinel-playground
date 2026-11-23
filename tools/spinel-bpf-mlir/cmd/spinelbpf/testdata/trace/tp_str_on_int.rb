require "bpf"

# E142 (P028) の H5: sys_enter_openat の flags (int — offset 32、size 8) を :user_str と宣言して読む — compile は通り、load の前の
# tpfield … strptr の照合 (tracefs の char * 深度 1 — bpf-mlir E546) が止める。
Ev = Struct.new(:name, :status)
BPF.record(Ev, name: [:u8, 16], status: :i64)
Events = BPF::RingBuf.new("Events", Ev.new(Array.new(16, 0), 0), 4096)

def on_bad(ctx)
  _ = Events.output_str(Ev.new(Array.new(16, 0), 0), :name, ctx.str_field(:flags), :status)
end
BPF.tracepoint :on_bad, "syscalls/sys_enter_openat", fields: {flags: [32, :user_str]}

require "spinelbpf"

begin
  obj = SpinelBPF.load_embedded
  puts "load kind=OK"
  obj.close
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
end
