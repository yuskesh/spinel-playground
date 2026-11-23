require "bpf"

# E144 (P028) の H5: bpf_modify_return_test (引数 2 つ) を nargs: 3 と宣言 — compile は通り、load の前の retsig の照合 (引数の数) が止める。
def on_bad(ctx)
  BPF::FMOD_CALL
end
BPF.fmod_ret :on_bad, "bpf_modify_return_test", nargs: 3

require "spinelbpf"

begin
  obj = SpinelBPF.load_embedded
  puts "load kind=OK"
  obj.close
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
end
