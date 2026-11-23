require "bpf"

# P024 E100: uprobe — target/cfix の greet(const char *s, uint32_t n)。同じ文字列を Keep へ output_str (いつも submit) と Drop へ
# output_str_or_discard (read_str の status < 0 — NULL 等 — なら捨てる) で送り、捨ての側の r / r.sent / r.status を Seen に写す。
Greet = Struct.new(:pid_tgid, :n, :_pad0, :status, :name)
BPF.record(Greet, pid_tgid: :u64, n: :u32, _pad0: :u32, status: :i64, name: [:u8, 32])
Keep = BPF::RingBuf.new("Keep", Greet.new(0, 0, 0, 0, Array.new(32, 0)), 4096)
Drop = BPF::RingBuf.new("Drop", Greet.new(0, 0, 0, 0, Array.new(32, 0)), 4096)
Seen = BPF::ArrayMap.new("Seen", :i64, 4)

def on_greet(ctx)
  _ = Keep.output_str(Greet.new(BPF.pid_tgid, ctx.arg(2), 0, 0, Array.new(32, 0)), :name, ctx.str_arg(1), :status)
  r = Drop.output_str_or_discard(Greet.new(BPF.pid_tgid, ctx.arg(2), 0, 0, Array.new(32, 0)), :name, ctx.str_arg(1), :status)
  if r
    Seen.update(0, 1)
    if r.sent
      Seen.update(1, 1)
    else
      Seen.update(1, 0)
    end
    Seen.update(2, r.status)
  else
    Seen.update(0, 0)
  end
end
BPF.uprobe :on_greet, "target/cfix", "greet", params: {1 => :user_str, 2 => :u32}
