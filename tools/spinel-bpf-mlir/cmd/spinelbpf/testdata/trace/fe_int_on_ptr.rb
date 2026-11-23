require "bpf"

# E117 (P026) の H5: bpf_fentry_test6 の b (void *) を :u64 と宣言して読む — compile は通り、load の前の farg の照合 (target の FUNC_PROTO) が止める。
Out = BPF::ArrayMap.new("Out", :i64, 1)

def on_bad(ctx)
  Out.update(0, ctx.arg(1) & 1)
end
BPF.fentry :on_bad, "bpf_fentry_test6", args: {1 => :u64}

require "spinelbpf"

begin
  obj = SpinelBPF.load_embedded
  puts "load kind=OK"
  obj.close
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
end
