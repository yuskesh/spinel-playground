require "bpf"

# E113 (P026): attach の kind の負の対照 — raw_tp の program を kprobe として、kprobe の program を raw_tp として attach すると誤り
# (bml が attach の後の link の info と照らす — 黙って通らない)。正しい kind の attach と detach は OK。
Calls = BPF::ArrayMap.new("Calls", :u64, 2)

def on_k(ctx)
  Calls.atomic_add(0, 1)
end
BPF.kprobe :on_k, "do_sys_poll", params: {2 => :u32}

def on_t(ctx)
  Calls.atomic_add(1, 1)
end
BPF.raw_tp :on_t, "sys_enter"

require "spinelbpf"

obj = SpinelBPF.load_embedded
begin
  obj.attach_kprobe("on_t")
  puts "raw_tp as kprobe kind=OK"
rescue SpinelBPF::Error => e
  puts "raw_tp as kprobe kind=#{e.class} msg=#{e.message}"
end
begin
  obj.attach_raw_tp("on_k")
  puts "kprobe as raw_tp kind=OK"
rescue SpinelBPF::Error => e
  puts "kprobe as raw_tp kind=#{e.class} msg=#{e.message}"
end
l = obj.attach_raw_tp("on_t")
puts "raw_tp as raw_tp kind=OK"
l.detach
puts "detached"
obj.close
