require "bpf"

# E121 H4 (追補 1): user 空間の lpm_trie の API — 往復・境界の値・満杯・誤りの class (MapMismatch・ValueRange・NotFound・Other)・eBPF の側との行き来。root (load)
R = BPF::LpmTrieMap.new("R", :u32, 8)
N = BPF::LpmTrieMap.new("N", :i32, 4)
F = BPF::LpmTrieMap.new("F", :u32, 2)
A = BPF::ArrayMap.new("A", :i64, 2)
H = BPF::HashMap.new("H", :u32, :u64, 2)

def prog(ctx)
  w = ctx.check(0, 34)
  if w
    p = R.lookup(w.u8(30), w.u8(31), w.u8(32), w.u8(33))
    if p
      A.update(0, p.load)
    end
    q = N.lookup(10, 0, 0, w.u8(33))
    if q
      A.update(1, q.load)
    end
    f = F.lookup(w.u8(30), 0, 0, 0)
    if f
      A.atomic_add(0, f.load)
    end
  end
  _ = H.delete(1) # H も eBPF の側で使う (使わない map は ELF から外れる)
  BPF::XDP_PASS
end
BPF.xdp :prog

require "spinelbpf"

obj = SpinelBPF.load_embedded

def try(label)
  begin
    yield
    puts "#{label} ok"
  rescue => e
    puts "#{label} err=#{e.class}"
  end
end

def frame(a, b, c, d)
  f = Array.new(34, 0)
  f[30] = a
  f[31] = b
  f[32] = c
  f[33] = d
  f
end

# 往復と最長一致 (u32 — /0・入れ子・/32・値 0 と 0xFFFFFFFF)
obj.lpm_put(R, "10.0.0.0/8", 1)
obj.lpm_put(R, "10.1.0.0/16", 2)
obj.lpm_put(R, "10.1.2.3/32", 4294967295)
obj.lpm_put(R, "0.0.0.0/0", 0)
puts "m1=#{obj.lpm_match(R, "10.1.2.3")} m2=#{obj.lpm_match(R, "10.1.9.9")} m3=#{obj.lpm_match(R, "10.9.9.9")} m4=#{obj.lpm_match(R, "11.0.0.0")}"
obj.test_run_xdp_packet("prog", frame(10, 1, 2, 3))
puts "A0=#{obj.map_get(A, 0)}"
puts "list=#{obj.lpm_list(R).sort.join(";")}"
puts "rm=#{obj.lpm_remove(R, "10.1.2.3/32")} rm2=#{obj.lpm_remove(R, "10.1.2.3/32")}"
puts "m1b=#{obj.lpm_match(R, "10.1.2.3")}"
obj.lpm_remove(R, "0.0.0.0/0")
try("match 11") { obj.lpm_match(R, "11.0.0.0") }
puts "has11=#{obj.lpm_has(R, "11.0.0.0")} has10=#{obj.lpm_has(R, "10.0.0.0")}"
try("put R -1") { obj.lpm_put(R, "1.0.0.0/8", -1) }
try("put R 2^32") { obj.lpm_put(R, "1.0.0.0/8", 4294967296) }
# 符号付き (i32)
obj.lpm_put(N, "10.0.0.0/24", -2147483648)
obj.lpm_put(N, "10.0.0.128/25", 2147483647)
obj.lpm_put(N, "10.0.0.7/32", -1)
puts "n1=#{obj.lpm_match(N, "10.0.0.1")} n2=#{obj.lpm_match(N, "10.0.0.200")} n3=#{obj.lpm_match(N, "10.0.0.7")}"
obj.test_run_xdp_packet("prog", frame(10, 0, 0, 7))
puts "A1=#{obj.map_get(A, 1)}"
puts "nlist=#{obj.lpm_list(N).sort.join(";")}"
try("put N 2^31") { obj.lpm_put(N, "1.0.0.0/8", 2147483648) }
try("put N -2^31-1") { obj.lpm_put(N, "1.0.0.0/8", -2147483649) }
# 満杯 (max_entries 2): 新しい prefix は ENOSPC、在る prefix の上書きは成功、消した後は入る
obj.lpm_put(F, "1.0.0.0/8", 1)
obj.lpm_put(F, "2.0.0.0/8", 2)
begin
  obj.lpm_put(F, "3.0.0.0/8", 3)
  puts "put F3 ok"
rescue SpinelBPF::Other => e
  puts "put F3 err=#{e.class} enospc=#{e.message.include?("ENOSPC — map is full")}"
end
obj.lpm_put(F, "2.0.0.0/8", 20)
puts "F2=#{obj.lpm_match(F, "2.1.1.1")}"
obj.lpm_remove(F, "1.0.0.0/8")
obj.lpm_put(F, "3.0.0.0/8", 3)
puts "F3=#{obj.lpm_match(F, "3.3.3.3")}"
# prefix / address の誤り (bml が kernel に触らずに止める)
try("put IPv6") { obj.lpm_put(R, "::1/128", 1) }
begin
  obj.lpm_put(R, "10.1.2.3/8", 1)
  puts "host bits ok"
rescue SpinelBPF::Other => e
  puts "host bits err=#{e.class} hint=#{e.message.include?("use 10.0.0.0/8")}"
end
try("put /33") { obj.lpm_put(R, "10.0.0.0/33", 1) }
try("match bad addr") { obj.lpm_match(R, "10.0.0") }
# 種類の食い違い (単相の API)
try("lpm_put on A") { obj.lpm_put(A, "1.0.0.0/8", 1) }
try("map_put on R") { obj.map_put(R, 0, 1) }
try("hash_put on R") { obj.hash_put(R, 1, 1) }
try("lpm_list on H") { obj.lpm_list(H) }
puts "plen=#{SpinelBPF.lpm_prefix_len("10.0.0.0/8")} #{SpinelBPF.lpm_prefix_len("0.0.0.0/0")} #{SpinelBPF.lpm_prefix_len("1.2.3.4/32")}"
obj.close
puts "done"
