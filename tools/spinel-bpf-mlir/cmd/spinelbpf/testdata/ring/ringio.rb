require "bpf"

# E027: ring buffer の user 空間の reader — test run ごとに event を 1 つ (値は packet の bytes から)、往復・順・期限切れ・状態
Ev = Struct.new(:seq, :neg, :tag, :_pad0, :_pad1, :t)
BPF.record(Ev, seq: :u32, neg: :i32, tag: :i16, _pad0: :u16, _pad1: :u32, t: :u64)

Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0, 0, 0, 0), 4096)
Drops = BPF::ArrayMap.new("Drops", :u64, 1)

def emit(ctx)
  w = ctx.check(0, 14)
  if w
    unless Events.output(Ev.new(w.be32(0), w.u8(4) - 128, -300, 0, 0, BPF.ktime_ns))
      Drops.atomic_add(0, 1)
    end
  end
  BPF::XDP_PASS
end
BPF.xdp :emit

require "spinelbpf"

obj = SpinelBPF.load_embedded

def frame(seq, b4)
  a = Array.new(14, 0)
  a[0] = (seq >> 24) & 0xFF
  a[1] = (seq >> 16) & 0xFF
  a[2] = (seq >> 8) & 0xFF
  a[3] = seq & 0xFF
  a[4] = b4
  a
end

def show(label, v)
  if v.length == 0
    puts "#{label} empty"
  else
    puts "#{label} seq=#{v[0]} neg=#{v[1]} tag=#{v[2]} pad=#{v[3]},#{v[4]} t>0=#{v[5] > 0} n=#{v.length}"
  end
end

r = obj.ringbuf(Events)
obj.test_run_xdp_packet("emit", frame(1, 0))
obj.test_run_xdp_packet("emit", frame(4294967295, 255))
obj.test_run_xdp_packet("emit", frame(3, 128))
show("e1", r.read_record(100))
show("e2", r.read_record(100))
show("e3", r.read_record(100))
show("e4 t0", r.read_record(0))
t0 = Time.now
v = r.read_record(200)
ms = ((Time.now - t0) * 1000).to_i
puts "e5 t200 empty=#{v.length == 0} waited=#{ms >= 150 && ms < 1000}"
puts "drops=#{obj.map_get(Drops, 0)}"
r.close
begin
  r.read_record(0)
  puts "read after reader close ok"
rescue SpinelBPF::State => e
  puts "read after reader close State"
end
# P010 E042: 2 回目の close は C の loader (bml) では冪等で OK (Go の loader は State — 契約の差 (1))
begin
  r.close
  puts "close twice ok"
rescue SpinelBPF::State => e
  puts "close twice State"
end
r2 = obj.ringbuf(Events)
obj.test_run_xdp_packet("emit", frame(9, 1))
# P010 E042: test run の回数 0 は C の loader では ValueRange (Go の loader は 0 回で OK — 契約の差 (2))
begin
  obj.test_run_xdp("emit", 0)
  puts "run0 ok"
rescue SpinelBPF::ValueRange => e
  puts "run0 ValueRange"
end
obj.close
begin
  r2.read_record(0)
  puts "read after obj close ok"
rescue SpinelBPF::State => e
  puts "read after obj close State"
end
begin
  obj.ringbuf(Events)
  puts "open after obj close ok"
rescue SpinelBPF::State => e
  puts "open after obj close State"
end
puts "alive"
