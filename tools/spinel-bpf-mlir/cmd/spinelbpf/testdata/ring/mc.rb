require "bpf"

# E028 の H5: 多 CPU — 全ての CPU で同時に output、落ちた数を数える (受け取った数 + 落ちた数 = 送った数)
Ev = Struct.new(:n)
BPF.record(Ev, n: :u64)
Events = BPF::RingBuf.new("Events", Ev.new(0), 4096)
Drops = BPF::ArrayMap.new("Drops", :u64, 1)

def prog(ctx)
  unless Events.output(Ev.new(1))
    Drops.atomic_add(0, 1)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
