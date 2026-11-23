require "bpf"

# E111 (P026): attach の kind の負の対照 — kretprobe の program を kprobe として、kprobe の program を kretprobe として attach すると誤り
# (bml が attach の後の link の info と照らす — 黙って通らない)。正しい kind の attach と detach は OK。
Calls = BPF::ArrayMap.new("Calls", :u64, 2)

def on_k(ctx)
  Calls.atomic_add(0, 1)
end
BPF.kprobe :on_k, "do_sys_poll", params: {2 => :u32}

def on_r(ctx)
  Calls.atomic_add(1, 1)
end
BPF.kretprobe :on_r, "do_sys_poll", ret: :i32

require "spinelbpf"

obj = SpinelBPF.load_embedded
begin
  obj.attach_kprobe("on_r")
  puts "kretprobe as kprobe kind=OK"
rescue SpinelBPF::Error => e
  puts "kretprobe as kprobe kind=#{e.class} msg=#{e.message}"
end
begin
  obj.attach_kretprobe("on_k")
  puts "kprobe as kretprobe kind=OK"
rescue SpinelBPF::Error => e
  puts "kprobe as kretprobe kind=#{e.class} msg=#{e.message}"
end
l = obj.attach_kretprobe("on_r")
puts "kretprobe as kretprobe kind=OK"
l.detach
puts "detached"
obj.close
