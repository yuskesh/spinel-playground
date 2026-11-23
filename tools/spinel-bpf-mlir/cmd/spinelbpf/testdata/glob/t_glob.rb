require "bpf"

# E058 (P014): global 変数の差動の表 — 幅と符号の違う Config を読み map に写し、Counter に足す (双子と kernel で比べる)。
C8 = BPF::Config.new("C8", :u8)
S8 = BPF::Config.new("S8", :i8)
C16 = BPF::Config.new("C16", :u16)
S16 = BPF::Config.new("S16", :i16)
C32 = BPF::Config.new("C32", :u32)
S64 = BPF::Config.new("S64", :i64)
O64 = BPF::OptionalConfig.new("O64", :u64)
K32 = BPF::Counter.new("K32", :u32)
K64 = BPF::Counter.new("K64", :i64)
Out = BPF::ArrayMap.new("Out", :i64, 6)
Out64 = BPF::ArrayMap.new("Out64", :u64, 1)

def prog(ctx)
  Out.update(0, C8.value)
  Out.update(1, S8.value)
  Out.update(2, C16.value)
  Out.update(3, S16.value)
  Out.update(4, C32.value)
  Out.update(5, S64.value)
  Out64.update(0, O64.value)
  K32.add(C8.value - 1)
  K64.add(S16.value)
  BPF::XDP_PASS
end
BPF.xdp :prog
