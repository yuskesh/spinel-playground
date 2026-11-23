require "bpf"

# E021: user 空間の record の往復 — record の型 2 つ・全ての幅と符号・padding、eBPF の側の store と atomic_add
Wide = Struct.new(:u64, :i64, :u32, :i32, :u16, :i16, :u8, :i8, :_pad0)
BPF.record(Wide, u64: :u64, i64: :i64, u32: :u32, i32: :i32, u16: :u16, i16: :i16, u8: :u8, i8: :i8, _pad0: :u16)
Small = Struct.new(:a, :_pad0, :b)
BPF.record(Small, a: :u8, _pad0: :u8, b: :i16)

Ws = BPF::RecordMap.new("Ws", Wide.new(0, 0, 0, 0, 0, 0, 0, 0, 0), 4)
Ss = BPF::RecordMap.new("Ss", Small.new(0, 0, 0), 2)

def prog(ctx)
  p = Ws.lookup(0)
  if p
    p.load.i16 = -300
    p.atomic_add(:u64, 4611686018427387904)
    p.atomic_add(:i64, -4611686018427387904)
  end
  r = Ws.lookup(1)
  if r
    r.atomic_add(:i64, -1)
  end
  q = Ss.lookup(1)
  if q
    q.load.b = -100
  end
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

# 往復 (境界の値)
lo = Wide.new(0, -9223372036854775807, 0, -2147483648, 0, -32768, 0, -128, 0)
hi = Wide.new(9223372036854775807, 9223372036854775807, 4294967295, 2147483647, 65535, 32767, 255, 127, 0)
obj.map_put_record(Ws, 2, lo)
obj.map_put_record(Ws, 3, hi)
puts "lo #{obj.map_get_record(Ws, 2) == lo.to_a} #{obj.map_get_record(Ws, 2).inspect}"
puts "hi #{obj.map_get_record(Ws, 3) == hi.to_a} #{obj.map_get_record(Ws, 3).inspect}"
obj.map_put_record(Ss, 0, Small.new(200, 0, -5))
puts "small #{obj.map_get_record(Ss, 0).inspect}"
# eBPF の側の store と atomic_add
obj.map_put_record(Ss, 1, Small.new(7, 0, 0))
obj.map_put_record(Ws, 1, Wide.new(0, -9223372036854775807, 0, 0, 0, 0, 0, 0, 0))
obj.test_run_xdp("prog", 1)
try("get i64 -2^63") { obj.map_get_record(Ws, 1) }
puts "after1 #{obj.map_get_record(Ws, 0).inspect}"
puts "small1 #{obj.map_get_record(Ss, 1).inspect}"
obj.test_run_xdp("prog", 1)
try("get u64 2^63") { obj.map_get_record(Ws, 0) }
# ValueRange (put)
try("put u8 256") { obj.map_put_record(Ss, 0, Small.new(256, 0, 0)) }
try("put i16 -32769") { obj.map_put_record(Ss, 0, Small.new(0, 0, -32769)) }
try("put pad 1") { obj.map_put_record(Ss, 0, Small.new(0, 1, 0)) }
try("put u32 -1") { obj.map_put_record(Ws, 1, Wide.new(0, 0, -1, 0, 0, 0, 0, 0, 0)) }
try("put u64 -1") { obj.map_put_record(Ws, 1, Wide.new(-1, 0, 0, 0, 0, 0, 0, 0, 0)) }
try("put nil") { obj.map_put_record(Ss, 0, Small.new(1, 0, nil)) }
puts "small after bad puts #{obj.map_get_record(Ss, 0).inspect}"
v = [1, 0, 2]
s = Small.new(v[0], v[1], v[2])
puts "struct #{s.inspect}"
obj.close
