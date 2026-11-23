require "bpf"

# E077 (P019): sched_cls の user 空間 — lo への attach_tcx と link の向き (pass だけの program — host の lo の通信を変えない)、kind の取り違え、
# tc の test run (判定・byte の範囲・最小の長さ)。出力の行を試験が読む (root と非 root で同じ program)。
Counts = BPF::ArrayMap.new("Counts", :u64, 2)

def tc_in(skb)
  Counts.atomic_add(0, 1)
  BPF::TC_PASS
end

def tc_out(skb)
  Counts.atomic_add(1, 1)
  BPF::TC_PASS
end

def x(ctx)
  BPF::XDP_PASS
end
BPF.tcx :tc_in, :ingress
BPF.tcx :tc_out, :egress
BPF.xdp :x

require "spinelbpf"

def frame(n, et)
  b = Array.new(n, 0)
  if n >= 14
    b[12] = et >> 8
    b[13] = et & 0xFF
  end
  b
end

def run(obj, what, bytes)
  begin
    v = obj.test_run_tc_packet("tc_in", bytes)
    puts "#{what} ret=#{v}"
  rescue SpinelBPF::Error => e
    puts "#{what} err=#{e.class} msg=#{e.message}"
  end
end

begin
  obj = SpinelBPF.load_embedded
rescue SpinelBPF::Error => e
  puts "load err=#{e.class} msg=#{e.message}"
  exit 1
end
puts "load ok unmet=#{obj.unmet.length}"
li = obj.attach_tcx("tc_in", "lo")
lo = obj.attach_tcx("tc_out", "lo")
puts "dir tc_in=#{li.tcx_direction} tc_out=#{lo.tcx_direction}"
li.detach
li.detach
lo.detach
puts "detached"
begin
  obj.attach_tcx("x", "lo")
  puts "xdp as tcx kind=OK"
rescue SpinelBPF::Error => e
  puts "xdp as tcx kind=#{e.class} msg=#{e.message}"
end
begin
  obj.attach_xdp("tc_in", "lo")
  puts "tc as xdp kind=OK"
rescue SpinelBPF::Error => e
  puts "tc as xdp kind=#{e.class} msg=#{e.message}"
end
begin
  obj.attach_tcx("tc_in", "no-such-if0")
  puts "no if kind=OK"
rescue SpinelBPF::Error => e
  puts "no if kind=#{e.class} msg=#{e.message}"
end
c0 = obj.map_get(Counts, 0)
run(obj, "zero64", Array.new(64, 0))
puts "counted #{obj.map_get(Counts, 0) - c0}"
bad = Array.new(64, 0)
bad[5] = 256
run(obj, "byte256", bad)
run(obj, "len13", frame(13, 0))
run(obj, "ipv4_33", frame(33, 0x0800))
run(obj, "ipv4_34", frame(34, 0x0800))
run(obj, "ipv6_53", frame(53, 0x86DD))
run(obj, "ipv6_54", frame(54, 0x86DD))
obj.close
