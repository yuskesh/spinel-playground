require "bpf"

# E058 (P014): OptionalConfig だけの program — load_embedded (config 無し) で load でき値は 0
V = BPF::OptionalConfig.new("V", :u16)
Out = BPF::ArrayMap.new("Out", :u64, 1)

def prog(ctx)
  Out.update(0, V.value + 1)
  BPF::XDP_PASS
end
BPF.xdp :prog

require "spinelbpf"

begin
  obj = SpinelBPF.load_embedded
  obj.test_run_xdp("prog", 1)
  puts "load_embedded kind=OK V=#{obj.optional_get(V)} out=#{obj.map_get(Out, 0)}"
  obj.close
rescue SpinelBPF::Error => e
  puts "load_embedded kind=#{e.class} msg=#{e.message}"
end
