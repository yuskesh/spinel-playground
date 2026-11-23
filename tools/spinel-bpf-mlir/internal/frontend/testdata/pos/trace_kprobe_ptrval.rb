require "bpf"

# P028 E146: kprobe の pointer の引数の値 — do_sys_openat2(int dfd, const char __user *filename, struct open_how *how) の filename
# (register 2 — :ptr) の raw の 64 bit を i64 で (bpf-mlir E327 — 参照しない)。Filter の tgid のとき Out[0] = filename の address、
# Out[1] に 1 を足し、Seen (key は :i64 の address) に add_or_init(address, 1) — address を key に使う形
Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 2)
Seen = BPF::HashMap.new("Seen", :i64, :u64, 64)

def on_open(ctx)
  tgid = BPF.pid_tgid >> 32
  f = Filter.lookup(0)
  if f
    if f.load == tgid
      a = ctx.arg(2)
      Out.update(0, a)
      Out.atomic_add(1, 1)
      _ = Seen.add_or_init(a, 1)
    end
  end
end
BPF.kprobe :on_open, "do_sys_openat2", params: {2 => :ptr, 3 => :ptr}
