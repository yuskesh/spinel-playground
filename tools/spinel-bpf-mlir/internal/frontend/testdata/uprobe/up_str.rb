require "bpf"

# P020 E080: uprobe — target/cfix の greet(const char *s, uint32_t n)。s を ring の event の name (u8 の配列) へ output_str で読み、
# status を event の status (i64) にも書く。予約が取れれば status の符号で、取れなければ別の slot で数える。
Greet = Struct.new(:pid_tgid, :n, :_pad0, :status, :name)
BPF.record(Greet, pid_tgid: :u64, n: :u32, _pad0: :u32, status: :i64, name: [:u8, 32])
Events = BPF::RingBuf.new("Events", Greet.new(0, 0, 0, 0, Array.new(32, 0)), 4096)
Stats = BPF::ArrayMap.new("Stats", :u64, 3)

def on_greet(ctx)
  r = Events.output_str(Greet.new(BPF.pid_tgid, ctx.arg(2), 0, 0, Array.new(32, 0)), :name, ctx.str_arg(1), :status)
  if r
    if r.status < 0
      Stats.atomic_add(1, 1)
    else
      Stats.atomic_add(0, 1)
    end
  else
    Stats.atomic_add(2, 1)
  end
end
BPF.uprobe :on_greet, "target/cfix", "greet", params: {1 => :user_str, 2 => :u32}
