require "bpf"

# E128 H4: user 空間の netfilter の API — load の unmet、attach_netfilter と test_run_netfilter の誤りの class と判定。root (load)。成功する attach はしない
# (host の netns に付けない)
NfState = Struct.new(:hook, :pf)
BPF.kernel_type(NfState, "nf_hook_state", hook: :u8, pf: :u8)
StateT = BPF::KernelType.new(NfState.new(0, 0))
Skb = Struct.new(:len)
BPF.kernel_type(Skb, "sk_buff", len: :u32)
SkbT = BPF::KernelType.new(Skb.new(0))

Out = BPF::ArrayMap.new("Out", :u32, 4)

def small_only(ctx)
  st = ctx.state(StateT)
  sk = ctx.skb(SkbT)
  n = sk.load.len
  Out.update(0, st.load.hook)
  Out.update(1, st.load.pf)
  Out.update(2, n)
  Out.atomic_add(3, 1)
  return BPF::NF_DROP if n > 64
  BPF::NF_ACCEPT
end
BPF.netfilter :small_only

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

# n byte の IPv4 / UDP の packet (eth の header は無い — bpf-mlir の trcheck の ip: と同じ形)
def ip(n)
  b = Array.new(n, 0)
  b[0] = 0x45
  b[2] = (n >> 8) & 0xFF
  b[3] = n & 0xFF
  b[8] = 64
  b[9] = 17
  b
end

obj = SpinelBPF.load_embedded
puts "load ok unmet=#{obj.unmet.length}"
try("attach_netfilter xp") { obj.attach_netfilter("xp", 2, 3, 0) }
try("attach_netfilter pf 2^32") { obj.attach_netfilter("small_only", 4294967296, 3, 0) }
try("attach_socket small_only") { obj.attach_socket("small_only", 0) }
try("attach_cgroup small_only") { obj.attach_cgroup("small_only", 0) }
puts "out40 ret=#{obj.test_run_netfilter("small_only", ip(40), 2, 3)} Out0=#{obj.map_get(Out, 0)} Out1=#{obj.map_get(Out, 1)} Out2=#{obj.map_get(Out, 2)} Out3=#{obj.map_get(Out, 3)}"
puts "out100 ret=#{obj.test_run_netfilter("small_only", ip(100), 2, 3)} Out2=#{obj.map_get(Out, 2)} Out3=#{obj.map_get(Out, 3)}"
try("hook 5") { obj.test_run_netfilter("small_only", ip(40), 2, 5) }
try("run xp") { obj.test_run_netfilter("xp", ip(40), 2, 3) }
