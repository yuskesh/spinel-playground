require "bpf"

# E112 (P026): attach の kind の負の対照 — uretprobe の program を uprobe として、uprobe の program を uretprobe として attach すると誤り。
# 正しい kind の attach と detach は OK。ARGV[0] は target (cfix) の path
Calls = BPF::ArrayMap.new("Calls", :i64, 2)

def on_in(ctx)
  Calls.atomic_add(0, ctx.arg(1))
end
BPF.uprobe :on_in, "target/cfix", "sum_args", params: {1 => :i64}

def on_out(ctx)
  Calls.atomic_add(1, ctx.ret)
end
BPF.uretprobe :on_out, "target/cfix", "sum_args", ret: :i64

require "spinelbpf"

tg = SpinelBPF::UprobeTargets.new
tg.add("on_in", ARGV[0])
tg.add("on_out", ARGV[0])
obj = SpinelBPF.load_embedded_targets(SpinelBPF::ConfigSet.new, tg)
begin
  obj.attach_uprobe("on_out", 0)
  puts "uretprobe as uprobe kind=OK"
rescue SpinelBPF::Error => e
  puts "uretprobe as uprobe kind=#{e.class} msg=#{e.message}"
end
begin
  obj.attach_uretprobe("on_in", 0)
  puts "uprobe as uretprobe kind=OK"
rescue SpinelBPF::Error => e
  puts "uprobe as uretprobe kind=#{e.class} msg=#{e.message}"
end
l = obj.attach_uretprobe("on_out", 0)
puts "uretprobe as uretprobe kind=OK"
l.detach
puts "detached"
obj.close
