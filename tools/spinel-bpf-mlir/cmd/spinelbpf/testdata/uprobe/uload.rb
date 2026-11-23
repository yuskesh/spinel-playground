require "bpf"

# E081 (P020): uprobe の user 空間 — load の引数の target (UprobeTargets)・照合 (target 無し・別の build)・attach_uprobe (pid 0)・link の file。
#   uload <target の path> ok|none   (ok は load_embedded_targets、none は target 無しの load_embedded)
Args = BPF::ArrayMap.new("Args", :i64, 3)

def on_sum(ctx)
  Args.update(0, ctx.arg(1))
end
BPF.uprobe :on_sum, "target/cfix", "sum_args", params: {1 => :i64, 2 => :u32, 3 => :i32}

require "spinelbpf"

path = ARGV[0]
if ARGV[1] == "none"
  begin
    SpinelBPF.load_embedded
    puts "load none kind=OK"
  rescue SpinelBPF::Error => e
    puts "load none kind=#{e.class} msg=#{e.message}"
  end
  exit 0
end
tg = SpinelBPF::UprobeTargets.new
tg.add("on_sum", path)
obj = nil
begin
  obj = SpinelBPF.load_embedded_targets(SpinelBPF::ConfigSet.new, tg)
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
  exit 0
end
puts "load ok unmet=#{obj.unmet.length}"
begin
  l = obj.attach_uprobe("on_sum", 0)
  puts "attach ok file=#{obj.uprobe_link_file(l)}"
  l.detach
  puts "detached"
rescue SpinelBPF::Error => e
  puts "attach kind=#{e.class} msg=#{e.message}"
end
obj.close
