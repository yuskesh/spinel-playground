require "bpf"

# E115 (P026) の H6: attach の kind の負の対照 — ksyscall の program を kprobe として、kprobe の program を ksyscall として attach すると誤り
# (bml が program の種類を見る — 黙って通らない)。正しい kind の attach と detach は OK。
Calls = BPF::ArrayMap.new("Calls", :u64, 2)

def on_s(ctx)
  Calls.atomic_add(0, ctx.arg(1) & 1)
end
BPF.ksyscall :on_s, "prctl", params: {1 => :i32}

def on_k(ctx)
  Calls.atomic_add(1, 1)
end
BPF.kprobe :on_k, "do_sys_poll", params: {2 => :u32}

require "spinelbpf"

obj = SpinelBPF.load_embedded
begin
  obj.attach_kprobe("on_s")
  puts "ksyscall as kprobe kind=OK"
rescue SpinelBPF::Error => e
  puts "ksyscall as kprobe kind=#{e.class} msg=#{e.message}"
end
begin
  obj.attach_ksyscall("on_k")
  puts "kprobe as ksyscall kind=OK"
rescue SpinelBPF::Error => e
  puts "kprobe as ksyscall kind=#{e.class} msg=#{e.message}"
end
l = obj.attach_ksyscall("on_s")
puts "ksyscall as ksyscall kind=OK"
l.detach
puts "detached"
obj.close
