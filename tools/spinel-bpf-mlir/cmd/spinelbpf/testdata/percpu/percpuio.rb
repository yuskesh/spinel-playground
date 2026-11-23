require "bpf"

# E038 H3: per-CPU の map の意味 (host — process を taskset で 1 つの CPU に固定して走らせる): program の加算は固定した CPU の slot にだけ、
# percpu_hash の新しい element の他の CPU の slot は 0、user 空間の CPU ごとの put / get の往復 (12 byte の record — 8 の倍数でない大きさの丸め)
Stats = Struct.new(:packets, :bytes, :drops)
BPF.record(Stats, packets: :u32, bytes: :u32, drops: :u32)

PA = BPF::PerCpuRecordMap.new("PA", Stats.new(0, 0, 0), 2)
PI = BPF::PerCpuArrayMap.new("PI", :u64, 2)
PH = BPF::PerCpuHashMap.new("PH", :u32, :u64, 8)

def prog(ctx)
  p = PA.lookup(0)
  if p
    p.load.packets += 1
    p.load.bytes += 60
  end
  q = PI.lookup(1)
  if q
    PI.update(1, (q.load & 0xFFFF) + 2)
  end
  _ = PH.add_or_init(7, 5)
  BPF::XDP_PASS
end
BPF.xdp :prog

require "spinelbpf"

obj = SpinelBPF.load_embedded
ncpu = SpinelBPF.possible_cpus

def try(label)
  begin
    yield
    puts "#{label} ok"
  rescue => e
    puts "#{label} err=#{e.class}"
  end
end

# nz は 0 でない slot の添字
def nz(vs)
  out = []
  i = 0
  while i < vs.length
    if vs[i] != 0
      out.push(i)
    end
    i += 1
  end
  out
end

obj.test_run_xdp("prog", 3)
pa = obj.percpu_get_record(PA, 0)
packets = []
bytes = []
i = 0
while i < pa.length
  packets.push(pa[i][0])
  bytes.push(pa[i][1])
  i += 1
end
puts "PA[0] len_is_possible=#{pa.length == ncpu} packets_slots=#{nz(packets).inspect} sum=#{SpinelBPF.sum(packets)} bytes_sum=#{SpinelBPF.sum(bytes)}"
pi = obj.percpu_get(PI, 1)
puts "PI[1] slots=#{nz(pi).inspect} sum=#{SpinelBPF.sum(pi)}"
ph = obj.percpu_hash_get(PH, 7)
puts "PH[7] slots=#{nz(ph).inspect} sum=#{SpinelBPF.sum(ph)} has=#{obj.percpu_hash_has(PH, 7)} has8=#{obj.percpu_hash_has(PH, 8)}"
# user 空間の CPU ごとの put / get (12 byte の record)
recs = []
vs = []
i = 0
while i < ncpu
  recs.push(Stats.new(i + 1, 2 * i + 3, 4294967295 - i))
  vs.push(1000 + i)
  i += 1
end
obj.percpu_put_record(PA, 1, recs)
back = obj.percpu_get_record(PA, 1)
ok = back.length == ncpu
i = 0
while i < ncpu
  if back[i] != recs[i].to_a
    ok = false
  end
  i += 1
end
puts "PA[1] round trip=#{ok}"
obj.percpu_put(PI, 0, vs)
puts "PI[0] round trip=#{obj.percpu_get(PI, 0) == vs} sum_ok=#{SpinelBPF.sum(obj.percpu_get(PI, 0)) == SpinelBPF.sum(vs)}"
obj.percpu_hash_put(PH, 9, vs)
puts "PH[9] round trip=#{obj.percpu_hash_get(PH, 9) == vs} keys=#{obj.percpu_hash_keys(PH).sort.inspect}"
puts "del9=#{obj.percpu_hash_delete(PH, 9)} del9again=#{obj.percpu_hash_delete(PH, 9)}"
try("get PH[9]") { obj.percpu_hash_get(PH, 9) }
try("put short") { obj.percpu_put(PI, 0, [1]) }
try("map_get on PI") { obj.map_get(PI, 0) }
try("hash_get on PH") { obj.hash_get(PH, 7) }
try("percpu_get on PH") { obj.percpu_get(PH, 7) }
obj.close
puts "alive"
