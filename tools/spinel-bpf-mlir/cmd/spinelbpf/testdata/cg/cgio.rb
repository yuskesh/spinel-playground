require "bpf"

# E127 H4: user 空間の cgroup_skb の API — load の unmet、attach_cgroup と test_run_skb_packet の誤りの class (kind の取り違え・fd)。root (load)
Out = BPF::ArrayMap.new("Out", :u32, 2)

def small_in(skb)
  n = skb.len
  Out.update(0, n)
  pr = 0
  w = skb.check(0, 20)
  if w
    pr = w.u8(9)
  end
  Out.update(1, pr)
  return BPF::CG_DENY if n > 64
  BPF::CG_ALLOW
end

def small_out(skb)
  n = skb.len
  Out.update(0, n)
  pr = 0
  w = skb.check(0, 20)
  if w
    pr = w.u8(9)
  end
  Out.update(1, pr)
  return BPF::CG_DENY if n > 64
  BPF::CG_ALLOW
end
BPF.cgroup_skb :small_in, :ingress
BPF.cgroup_skb :small_out, :egress

def xp(ctx)
  Out.update(0, 7)
  BPF::XDP_PASS
end
BPF.xdp :xp

require "spinelbpf"

def try(label)
  begin
    yield
    puts "#{label} ok"
  rescue SpinelBPF::Error => e
    puts "#{label} err=#{e.class}"
  end
end

def frame(n, proto)
  f = Array.new(n, 0)
  if n > 23
    f[23] = proto
  end
  f
end

obj = SpinelBPF.load_embedded
puts "load ok unmet=#{obj.unmet.length}"
try("attach_cgroup xp") { obj.attach_cgroup("xp", 0) }
try("attach_cgroup nope") { obj.attach_cgroup("nope", 0) }
try("attach_cgroup stdin") { obj.attach_cgroup("small_in", 0) }
try("attach_socket small_in") { obj.attach_socket("small_in", 0) }
try("attach_tcx small_out") { obj.attach_tcx("small_out", "lo") }
try("attach_xdp small_in") { obj.attach_xdp("small_in", "lo") }
puts "in78 ret=#{obj.test_run_skb_packet("small_in", frame(78, 17))} Out0=#{obj.map_get(Out, 0)} Out1=#{obj.map_get(Out, 1)}"
puts "in79 ret=#{obj.test_run_skb_packet("small_in", frame(79, 6))} Out0=#{obj.map_get(Out, 0)} Out1=#{obj.map_get(Out, 1)}"
puts "out33 ret=#{obj.test_run_skb_packet("small_out", frame(33, 17))} Out0=#{obj.map_get(Out, 0)} Out1=#{obj.map_get(Out, 1)}"
puts "out34 ret=#{obj.test_run_skb_packet("small_out", frame(34, 255))} Out0=#{obj.map_get(Out, 0)} Out1=#{obj.map_get(Out, 1)}"
try("run13") { obj.test_run_skb_packet("small_in", Array.new(13, 0)) }
try("xdp run small_in") { obj.test_run_xdp_packet("small_in", Array.new(64, 0)) }
