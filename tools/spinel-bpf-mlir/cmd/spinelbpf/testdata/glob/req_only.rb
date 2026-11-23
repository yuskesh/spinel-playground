require "bpf"

# E058 (P014): 必須の Config を持つ program — load_embedded は ConfigNotSet、set の値の範囲、Counter への set は誤り、set してからの load と読み
P = BPF::Config.new("P", :u16)
S = BPF::Config.new("S", :i8)
U = BPF::Config.new("U", :u8)
N = BPF::Counter.new("N", :i64)
Out = BPF::ArrayMap.new("Out", :i64, 1)

def prog(ctx)
  Out.update(0, P.value + S.value + U.value)
  N.add(S.value)
  BPF::XDP_PASS
end
BPF.xdp :prog

require "spinelbpf"

def try_set(label, cfg, g, v)
  begin
    cfg.set(g, v)
    puts "#{label} kind=OK"
  rescue SpinelBPF::Error => e
    puts "#{label} kind=#{e.class} msg=#{e.message}"
  end
end

begin
  SpinelBPF.load_embedded
  puts "load_embedded kind=OK"
rescue SpinelBPF::Error => e
  puts "load_embedded kind=#{e.class} msg=#{e.message}"
end
cfg = SpinelBPF::ConfigSet.new
try_set("set P 70000", cfg, P, 70000)
try_set("set S -129", cfg, S, -129)
try_set("set U -1", cfg, U, -1)
begin
  cfg.set(N, 1)
  puts "set counter kind=OK"
rescue SpinelBPF::Error => e
  puts "set counter kind=#{e.class} msg=#{e.message}"
end
cfg.set(P, 8080)
cfg.set(S, -5)
cfg.set(U, 200)
obj = SpinelBPF.load_embedded_config(cfg)
obj.test_run_xdp("prog", 3)
puts "loaded P=#{obj.config_get(P)} S=#{obj.config_get(S)} U=#{obj.config_get(U)} out=#{obj.map_get(Out, 0)} N=#{obj.counter_get(N)}"
obj.close
