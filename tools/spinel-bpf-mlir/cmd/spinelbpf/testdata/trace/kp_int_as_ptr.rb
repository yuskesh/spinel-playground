require "bpf"

# E146 (P028) の H5: do_sys_openat2 の第 1 引数 (int dfd) を :ptr と宣言して値を読む — compile は通り、load の前の kprobearg の照合 (target の引数が
# pointer か — bpf-mlir E327) が止める。
Out = BPF::ArrayMap.new("Out", :i64, 1)

def on_bad(ctx)
  Out.update(0, ctx.arg(1))
end
BPF.kprobe :on_bad, "do_sys_openat2", params: {1 => :ptr}

require "spinelbpf"

begin
  obj = SpinelBPF.load_embedded
  puts "load kind=OK"
  obj.close
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
end
