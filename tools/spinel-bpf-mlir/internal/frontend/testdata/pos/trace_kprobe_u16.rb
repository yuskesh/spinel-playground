require "bpf"

# E059 (E058 のレビュー): kprobe の 16 bit の引数の加算 — 8 / 16 bit の区間が正しい今は溢れない (E058 の前は 64 bit の区間で偽の SB014)
Sums = BPF::HashMap.new("Sums", :u32, :u64, 64)

def on_poll(ctx)
  tgid = BPF.pid_tgid >> 32
  _ = Sums.add_or_init(tgid, ctx.arg(2) + 1)
end
BPF.kprobe :on_poll, "do_sys_poll", params: {2 => :u16}
