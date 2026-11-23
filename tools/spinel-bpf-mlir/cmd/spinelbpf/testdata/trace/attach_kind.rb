require "bpf"

# E053 (P013): attach の kind の負の対照 — fentry の program を kprobe / fexit として attach すると誤り (黙って通らない)、fentry として attach と detach は OK。
Calls = BPF::ArrayMap.new("Calls", :u64, 1)

def on_test1(ctx)
  Calls.atomic_add(0, 1)
end
BPF.fentry :on_test1, "bpf_fentry_test1"

require "spinelbpf"

obj = SpinelBPF.load_embedded
begin
  obj.attach_kprobe("on_test1")
  puts "as kprobe kind=OK"
rescue SpinelBPF::Error => e
  puts "as kprobe kind=#{e.class} msg=#{e.message}"
end
begin
  obj.attach_fexit("on_test1")
  puts "as fexit kind=OK"
rescue SpinelBPF::Error => e
  puts "as fexit kind=#{e.class} msg=#{e.message}"
end
l = obj.attach_fentry("on_test1")
puts "as fentry kind=OK"
tid = obj.test_run_tracing("on_test1", 3)
puts "runs tid_is_other=#{tid != Process.pid} calls>=3 #{obj.map_get(Calls, 0) >= 3}"
l.detach
puts "detached"
obj.close
