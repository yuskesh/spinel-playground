require "bpf"

# E115 (P026) の H5: prctl の第 1 引数 (format は int — 4 byte の符号付き) を :u64 と宣言して読む — schema-check は通り (着手前の確かめ)、
# load の前の sysarg の照合が止める (幅と符号の誤りは黙って別の値を読む)。
Out = BPF::ArrayMap.new("Out", :u64, 1)

def on_k(ctx)
  Out.update(0, ctx.arg(1))
end
BPF.ksyscall :on_k, "prctl", params: {1 => :u64}

require "spinelbpf"

begin
  obj = SpinelBPF.load_embedded
  puts "load kind=OK"
  obj.close
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
end
