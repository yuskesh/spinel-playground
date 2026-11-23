require "bpf"

# E114 (P026) の H6: attach の kind の負の対照 — tracepoint の program を raw_tp として、raw_tp の program を tracepoint として attach すると誤り
# (bml が program の種類を見る — 黙って通らない)。正しい kind の attach と detach は OK。
Calls = BPF::ArrayMap.new("Calls", :u64, 2)

def on_t(ctx)
  Calls.atomic_add(0, ctx.field(:__syscall_nr) & 1)
end
BPF.tracepoint :on_t, "syscalls/sys_enter_write", fields: {__syscall_nr: [8, :i32]}

def on_r(ctx)
  Calls.atomic_add(1, 1)
end
BPF.raw_tp :on_r, "sys_enter"

require "spinelbpf"

obj = SpinelBPF.load_embedded
begin
  obj.attach_raw_tp("on_t")
  puts "tracepoint as raw_tp kind=OK"
rescue SpinelBPF::Error => e
  puts "tracepoint as raw_tp kind=#{e.class} msg=#{e.message}"
end
begin
  obj.attach_tracepoint("on_r")
  puts "raw_tp as tracepoint kind=OK"
rescue SpinelBPF::Error => e
  puts "raw_tp as tracepoint kind=#{e.class} msg=#{e.message}"
end
l = obj.attach_tracepoint("on_t")
puts "tracepoint as tracepoint kind=OK"
l.detach
puts "detached"
obj.close
