require "bpf"

# E144 (P028) の H5 (追補 2): bpf_fentry_test2 (int (int a, u64 b) — 7.1.8 の fmodret の集合 (net/bpf/test_run.c 647〜652 行) にも
# error injection の一覧にも無い — bpf-mlir E400 の追試と同じ対照) への fmod_ret。署名は一致するので照合は通り、kernel が load
# (verifier.c の check_attach_modify_return) で拒否する (止まる段と文は予測しない)。追補 1 までの bpf_fentry_test1 は fmodret の集合に在った (外れ)
def on_bad(ctx)
  BPF::FMOD_CALL
end
BPF.fmod_ret :on_bad, "bpf_fentry_test2", nargs: 2, args: {0 => :i32}

require "spinelbpf"

begin
  obj = SpinelBPF.load_embedded
  puts "load kind=OK"
  obj.close
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
end
