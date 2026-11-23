require "bpf"

# E033: user 空間の hash の API — 4 つの組 (整数 / record の key × 整数 / record の値)・無い key・状態・列挙・eBPF の側との行き来
K = Struct.new(:proto, :_pad0, :port, :addr)
BPF.record(K, proto: :u8, _pad0: :u8, port: :u16, addr: :u32)
S = Struct.new(:frames, :delta, :_pad0)
BPF.record(S, frames: :u64, delta: :i32, _pad0: :u32)

A = BPF::HashMap.new("A", :i64, :i64, 8)
B = BPF::HashMap.new("B", :u32, :u64, 2)
C = BPF::RecordHashMap.new("C", :u32, S.new(0, 0, 0), 8)
D = BPF::HashMap.new("D", K.new(0, 0, 0, 0), :i32, 8)
E = BPF::LruRecordHashMap.new("E", K.new(0, 0, 0, 0), S.new(0, 0, 0), 8)

def prog(ctx)
  _ = A.insert(100, -7)
  _ = D.insert(K.new(6, 0, 80, 167772161), -5)
  p = A.lookup(5)
  if p
    _ = A.update(6, (p.load & 0xFFFF) + 1)
  end
  _ = B.delete(9) # B・C・E も eBPF の側で使う (使わない map は ELF から外れる — user 空間は読めない)
  _ = C.delete(9)
  _ = E.delete(K.new(9, 0, 9, 9))
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

# 整数の key と整数の値 (i64 / i64)
obj.hash_put(A, 5, 41)
obj.hash_put(A, -9223372036854775807, 9223372036854775807)
puts "A[5]=#{obj.hash_get(A, 5)} A[min]=#{obj.hash_get(A, -9223372036854775807)}"
obj.test_run_xdp("prog", 1)
puts "A[100]=#{obj.hash_get(A, 100)} A[6]=#{obj.hash_get(A, 6)}"
puts "has100=#{obj.hash_has(A, 100)} has7=#{obj.hash_has(A, 7)}"
try("get A[7]") { obj.hash_get(A, 7) }
puts "del100=#{obj.hash_delete(A, 100)} del100again=#{obj.hash_delete(A, 100)}"
puts "keysA=#{obj.hash_keys(A).sort.inspect}"
# u32 / u64、満杯 (max_entries 2)、範囲の外
obj.hash_put(B, 1, 9223372036854775807)
obj.hash_put(B, 2, 0)
puts "B[1]=#{obj.hash_get(B, 1)}"
begin
  obj.hash_put(B, 3, 3)
  puts "put B[3] ok"
rescue SpinelBPF::Other => e
  puts "put B[3] err=#{e.class} e2big=#{e.message.include?("E2BIG — map is full")}"
end
obj.hash_put(B, 2, 5)
puts "B[2] after replace in a full map=#{obj.hash_get(B, 2)}"
try("put B value -1") { obj.hash_put(B, 1, -1) }
try("put B key 2^32") { obj.hash_put(B, 4294967296, 1) }
# 整数の key と record の値
obj.hash_put_record(C, 3, S.new(9223372036854775807, -5, 0))
puts "C[3]=#{obj.hash_get_record(C, 3).inspect}"
try("put C pad 1") { obj.hash_put_record(C, 4, S.new(1, 1, 1)) }
try("hash_get on C") { obj.hash_get(C, 3) }
try("hash_get_record on A") { obj.hash_get_record(A, 5) }
# record の key と整数の値
puts "D[6/80]=#{obj.hash_get_rk(D, K.new(6, 0, 80, 167772161))}"
obj.hash_put_rk(D, K.new(17, 0, 53, 16909060), 2147483647)
puts "D[17/53]=#{obj.hash_get_rk(D, K.new(17, 0, 53, 16909060))} has=#{obj.hash_has_rk(D, K.new(17, 0, 53, 16909060))} hasOther=#{obj.hash_has_rk(D, K.new(17, 0, 54, 16909060))}"
try("put D pad 1") { obj.hash_put_rk(D, K.new(17, 1, 53, 16909060), 1) }
try("get D missing") { obj.hash_get_rk(D, K.new(1, 0, 1, 1)) }
puts "keysD=#{obj.hash_keys_rk(D).sort.inspect}"
# record の key と record の値 (lru)
obj.hash_put_record_rk(E, K.new(1, 0, 2, 3), S.new(4, -6, 0))
puts "E=#{obj.hash_get_record_rk(E, K.new(1, 0, 2, 3)).inspect}"
puts "delE=#{obj.hash_delete_rk(E, K.new(1, 0, 2, 3))} delEagain=#{obj.hash_delete_rk(E, K.new(1, 0, 2, 3))}"
try("get E missing") { obj.hash_get_record_rk(E, K.new(1, 0, 2, 3)) }
obj.close
puts "alive"
