require "bpf"

# E114 (P026) の H5: sys_enter_write の fd を offset 24 (buf の位置) の u64 と宣言して読む — schema と op は一致するので compile は通り、
# load の前の tracefs の照合 (tpfield) が止める (verifier は通るはずの別の field の黙った読み)。
Out = BPF::ArrayMap.new("Out", :i64, 1)

def on_w(ctx)
  Out.update(0, ctx.field(:fd) & 0xFFFF_FFFF)
end
BPF.tracepoint :on_w, "syscalls/sys_enter_write", fields: {fd: [24, :u64]}

require "spinelbpf"

begin
  obj = SpinelBPF.load_embedded
  puts "load kind=OK"
  obj.close
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
end
