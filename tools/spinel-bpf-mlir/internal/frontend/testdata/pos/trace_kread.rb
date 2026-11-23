require "bpf"

# P026 E116: kprobe の pointer の引数の先の固定幅の読み — do_sys_openat2(int dfd, const char *filename, struct open_how *how)。
# how は kernel の stack に写された struct open_how (flags @0・mode @8・resolve @16 — 読みは成功)、filename は user の pointer
# (probe_read_kernel は失敗 — 値 0 と負の status)。Filter の tgid で how->mode の下位 32 bit が 0x4511_6000 (自分の他の open は mode で除く) のとき
# Out[0] に 1 を足し・Out[1] = resolve の下位 8 bit・Out[2] = resolve の読みの status・Out[3] = filename の読みの status・Out[4] = その値
Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 5)

def on_open(ctx)
  tgid = BPF.pid_tgid >> 32
  f = Filter.lookup(0)
  if f
    if f.load == tgid
      m, mst = ctx.read(3, 8, :u64)
      if mst == 0
        if (m & 0xFFFF_FFFF) == 0x4511_6000
          r, rst = ctx.read(3, 16, :u64)
          c, cst = ctx.read(2, 0, :u8)
          Out.atomic_add(0, 1)
          Out.update(1, r & 0xFF)
          Out.update(2, rst)
          Out.update(3, cst)
          Out.update(4, c)
        end
      end
    end
  end
end
BPF.kprobe :on_open, "do_sys_openat2", params: {2 => :ptr, 3 => :ptr}
