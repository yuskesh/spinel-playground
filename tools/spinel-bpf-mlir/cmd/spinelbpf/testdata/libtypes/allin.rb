require "bpf"

# E040 H6: library の型の静的な試験の「全部入り」の program — 全ての map の class と全ての公開の API を 1 つの program で使う。
# Spinel の --emit-rbs で library (SpinelBPF・bpf.rb の class) の signature と instance 変数に untyped が無いことを見る (E039 のレビューの P3)。
K = Struct.new(:a, :_pad0, :b)
BPF.record(K, a: :u16, _pad0: :u16, b: :u32)
S = Struct.new(:x, :y)
BPF.record(S, x: :u64, y: :i64)

A = BPF::ArrayMap.new("A", :i64, 2)
R = BPF::RecordMap.new("R", S.new(0, 0), 2)
Q = BPF::RingBuf.new("Q", S.new(0, 0), 4096)
H = BPF::HashMap.new("H", :u32, :u64, 4)
HK = BPF::LruHashMap.new("HK", K.new(0, 0, 0), :i32, 4)
HR = BPF::RecordHashMap.new("HR", :i64, S.new(0, 0), 4)
HKR = BPF::LruRecordHashMap.new("HKR", K.new(0, 0, 0), S.new(0, 0), 4)
PA = BPF::PerCpuArrayMap.new("PA", :u32, 2)
PR = BPF::PerCpuRecordMap.new("PR", S.new(0, 0), 2)
PH = BPF::PerCpuHashMap.new("PH", K.new(0, 0, 0), :i64, 4)
PHR = BPF::PerCpuRecordHashMap.new("PHR", :u32, S.new(0, 0), 4)
LP = BPF::LpmTrieMap.new("LP", :i32, 4)

def prog(ctx)
  A.atomic_add(0, 1)
  A.atomic_add(1, ctx.ingress_ifindex)
  _ = ctx.adjust_head(0)
  _ = ctx.adjust_tail(0)
  R.update(0, S.new(1, 2))
  _ = Q.output(S.new(3, 4))
  _ = H.add_or_init(1, 1)
  _ = HK.update(K.new(1, 0, 2), 3)
  _ = HR.insert(-1, S.new(5, 6))
  _ = HKR.replace(K.new(1, 0, 2), S.new(7, 8))
  p = PA.lookup(0)
  if p
    PA.update(0, (p.load & 0xFFFF) + 1)
  end
  q = PR.lookup(1)
  if q
    q.load.x += 1
  end
  _ = PH.add_or_init(K.new(3, 0, 4), 1)
  _ = PHR.delete(9)
  l = LP.lookup(10, 0, 0, 1)
  if l
    A.update(1, l.load)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog

def sfp(skb)
  A.atomic_add(1, skb.len)
  BPF::SF_KEEP
end
BPF.socket_filter :sfp

def cgp(skb)
  A.atomic_add(1, skb.len)
  BPF::CG_ALLOW
end
BPF.cgroup_skb :cgp, :egress

NfS = Struct.new(:hook, :pf)
BPF.kernel_type(NfS, "nf_hook_state", hook: :u8, pf: :u8)
NfST = BPF::KernelType.new(NfS.new(0, 0))

def nfp(ctx)
  st = ctx.state(NfST)
  A.atomic_add(1, st.load.hook)
  BPF::NF_ACCEPT
end
BPF.netfilter :nfp

def tcm(skb)
  A.atomic_add(1, skb.len + skb.mark)
  skb.mark = 5
  BPF::TC_PASS
end
BPF.tcx :tcm, :ingress

def flp(ctx)
  ctx.set_key(:ip_proto, 6)
  A.atomic_add(1, ctx.key(:nhoff))
  BPF::FLOW_OK
end
BPF.flow_dissector :flp

require "spinelbpf"

obj = SpinelBPF.load_embedded
puts obj.unmet.length
puts SpinelBPF.policy_version
obj.map_put(A, 1, obj.map_get(A, 0))
v = obj.map_get_record(R, 0)
obj.map_put_record(R, 1, S.new(v[0], v[1]))
obj.test_run_xdp("prog", 1)
obj.test_run_xdp_packet("prog", Array.new(14, 0))
r = obj.ringbuf(Q)
e = r.read_record(0)
if e.length > 0
  puts S.new(e[0], e[1]).x
end
r.close
obj.hash_put(H, 1, obj.hash_get(H, 1))
puts obj.hash_has(H, 2)
puts obj.hash_delete(H, 2)
puts obj.hash_keys(H).length
obj.hash_put_rk(HK, K.new(1, 0, 2), obj.hash_get_rk(HK, K.new(1, 0, 2)))
puts obj.hash_has_rk(HK, K.new(1, 0, 2))
puts obj.hash_delete_rk(HK, K.new(1, 0, 2))
ks = obj.hash_keys_rk(HK)
puts ks.length
w = obj.hash_get_record(HR, -1)
obj.hash_put_record(HR, -1, S.new(w[0], w[1]))
z = obj.hash_get_record_rk(HKR, K.new(1, 0, 2))
obj.hash_put_record_rk(HKR, K.new(1, 0, 2), S.new(z[0], z[1]))
pa = obj.percpu_get(PA, 0)
obj.percpu_put(PA, 0, pa)
puts SpinelBPF.sum(pa)
pr = obj.percpu_get_record(PR, 1)
recs = []
i = 0
while i < pr.length
  recs.push(S.new(pr[i][0], pr[i][1]))
  i += 1
end
obj.percpu_put_record(PR, 1, recs)
ph = obj.percpu_hash_get_rk(PH, K.new(3, 0, 4))
obj.percpu_hash_put_rk(PH, K.new(3, 0, 4), ph)
puts obj.percpu_hash_has_rk(PH, K.new(3, 0, 4))
puts obj.percpu_hash_keys_rk(PH).length
puts obj.percpu_hash_delete_rk(PH, K.new(3, 0, 4))
phr = obj.percpu_hash_get_record(PHR, 9)
obj.percpu_hash_put_record(PHR, 9, [S.new(phr[0][0], phr[0][1])])
puts obj.percpu_hash_has(PHR, 9)
puts obj.percpu_hash_keys(PHR).length
puts obj.percpu_hash_delete(PHR, 9)
obj.lpm_put(LP, "10.0.0.0/8", -1)
puts obj.lpm_match(LP, "10.0.0.1")
puts obj.lpm_has(LP, "10.0.0.1")
puts obj.lpm_list(LP).length
puts obj.lpm_remove(LP, "10.0.0.0/8")
puts SpinelBPF.lpm_prefix_len("10.0.0.0/8")
obj.attach_socket("sfp", 3)
puts obj.test_run_skb_packet("sfp", Array.new(64, 0))
cl = obj.attach_cgroup("cgp", 3)
cl.detach
nl = obj.attach_netfilter("nfp", 2, 3, 0)
nl.detach
puts obj.test_run_netfilter("nfp", Array.new(40, 0), 2, 3)
fr = obj.test_run_flow_dissector("flp", Array.new(64, 0))
puts fr[0] + fr.length
fl = obj.attach_netns("flp", 3)
fl.detach
puts SpinelBPF.possible_cpus
obj.close
