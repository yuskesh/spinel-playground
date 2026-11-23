require "bpf"

# E113 (P026) の H6 (b): sys_enter (引数は 2 つ) に args[11] を読む program — compile と load は通り (verifier は 96 byte の内を受ける)、
# test run は 12 個の引数で通り、attach は kernel が -EINVAL で拒む (program の ctx の最大の offset が tracepoint の引数の数 × 8 を超える)。
Seen = BPF::ArrayMap.new("Seen", :u64, 2)

def on_wide(ctx)
  Seen.update(0, ctx.arg(11) & 0xFFFF_FFFF)
  Seen.atomic_add(1, 1)
end
BPF.raw_tp :on_wide, "sys_enter"

require "spinelbpf"

obj = SpinelBPF.load_embedded
puts "load kind=OK"
r = obj.test_run_raw_tp("on_wide", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 77])
puts "test_run ret=#{r} seen0=#{obj.map_get(Seen, 0)} seen1=#{obj.map_get(Seen, 1)}"
begin
  obj.attach_raw_tp("on_wide")
  puts "attach kind=OK"
rescue SpinelBPF::Error => e
  puts "attach kind=#{e.class} msg=#{e.message}"
end
obj.close
