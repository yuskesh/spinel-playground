require "bpf"

# E144 (P028) の H5: bpf_modify_return_test の a (int — signed 32 bit) を :u64 と宣言して読む — compile は通り、load の前の farg の照合 (target の FUNC_PROTO) が止める。
Out = BPF::ArrayMap.new("Out", :i64, 1)

def on_bad(ctx)
  Out.update(0, ctx.arg(0) & 1)
  BPF::FMOD_CALL
end
BPF.fmod_ret :on_bad, "bpf_modify_return_test", nargs: 2, args: {0 => :u64}

require "spinelbpf"

begin
  obj = SpinelBPF.load_embedded
  puts "load kind=OK"
  obj.close
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
end
