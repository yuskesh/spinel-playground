require "bpf"

# funclatency — kernel の関数 (do_sys_openat2 — openat / openat2 の経路) の呼び出しの時間の log2 の histogram
# (bcc の funclatency、spinel-ebpf 23fa4b0 tools/funclatency.rb の移植 — P027 E135)。
# eBPF の側: kprobe で入りの時刻を thread (pid_tgid) の key で Start に、kretprobe で差を Hist に。Cfg[0] が 0 でなければその tgid だけ。
# 他の関数を測るには 2 つの宣言の関数の名前を替える (params は kprobe の宣言に要る 1 つ — 読まない)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Start = BPF::HashMap.new("Start", :u64, :u64, 10240)
Hist = BPF::ArrayMap.new("Hist", :u64, 64)

# log2_bucket は v (≥ 0) の 2 を底の対数の整数部 (0 は 0) — bcc の bpf_log2l と同じ bucket。
# 腕の最後の式を b の足しに (v の代入を最後にすると、引数の型を Spinel が推論できない呼び手で腕の値の型が typing の probe で変わり SB010 — E134)
def log2_bucket(v)
  b = 0
  if v >= 0x1_0000_0000
    v = v >> 32
    b += 32
  end
  if v >= 0x1_0000
    v = v >> 16
    b += 16
  end
  if v >= 0x100
    v = v >> 8
    b += 8
  end
  if v >= 0x10
    v = v >> 4
    b += 4
  end
  if v >= 4
    v = v >> 2
    b += 2
  end
  if v >= 2
    b += 1
  end
  b
end

def on_entry(ctx)
  id = BPF.pid_tgid & 0x7FFF_FFFF_FFFF_FFFF
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == (id >> 32)
      _ = Start.update(id, BPF.ktime_ns)
    end
  end
end
BPF.kprobe :on_entry, "do_sys_openat2", params: {1 => :i32}

def on_return(ctx)
  id = BPF.pid_tgid & 0x7FFF_FFFF_FFFF_FFFF
  t = Start.lookup(id)
  if t
    d = (BPF.ktime_ns & 0x7FFF_FFFF_FFFF_FFFF) - (t.load & 0x7FFF_FFFF_FFFF_FFFF)
    _ = Start.delete(id)
    if d > 0
      Hist.atomic_add(log2_bucket(d) & 63, 1) # bucket は 0〜63 — & 63 は値を変えない (helper の戻り値は i64 の全域)
    end
  end
end
BPF.kretprobe :on_return, "do_sys_openat2", ret: :i64

# user 空間の側 — 普通の Ruby (Spinel)。
#   funclatency [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) 測り log2 の histogram を印字
#   funclatency --selftest [N]                     自分の tgid に絞り open("/dev/null") を N 回 (既定 100) — Hist の合計の差 = N を照らす
require "spinelbpf"

# FL は自分の pid と open / close (例の中の inline C)。
module FL
  ffi_source <<~C
    #include <fcntl.h>
    #include <unistd.h>
    long fl_pid(void) { return (long)getpid(); }
    long fl_opens(long n) {
      long ok = 0;
      for (long i = 0; i < n; i++) { int fd = open("/dev/null", O_RDONLY); if (fd >= 0) { ok++; close(fd); } }
      return ok;
    }
  C
  ffi_func :fl_pid, [], :long
  ffi_func :fl_opens, [:long], :long
end

# hist_total は Hist の 64 の bucket の合計。
def hist_total(obj)
  s = 0
  b = 0
  while b < 64
    s += obj.map_get(Hist, b)
    b += 1
  end
  s
end

# print_hist は 0 でない bucket の範囲を bcc の形 (low -> high : count) で印字する。
def print_hist(obj, unit)
  lo = -1
  hi = -1
  b = 0
  while b < 64
    if obj.map_get(Hist, b) > 0
      lo = b if lo < 0
      hi = b
    end
    b += 1
  end
  puts "     #{unit}               : count"
  if lo < 0
    puts "     (no events)"
    return
  end
  b = lo
  while b <= hi
    low = b == 0 ? 0 : (1 << b)
    high = (1 << (b + 1)) - 1
    puts "#{low.to_s.rjust(20)} -> #{high.to_s.ljust(20)} : #{obj.map_get(Hist, b)}"
    b += 1
  end
end

USAGE = "usage: funclatency [--duration-ms MS] [--pid TGID] | --selftest [N]"
selftest = false
n = 100
pid = 0
duration_ms = 5000
i = 0
while i < ARGV.length
  a = ARGV[i]
  if a == "--selftest"
    selftest = true
    if i + 1 < ARGV.length && ARGV[i + 1].to_i > 0
      n = ARGV[i + 1].to_i
      i += 1
    end
    i += 1
  elsif a == "--pid" && i + 1 < ARGV.length
    pid = ARGV[i + 1].to_i
    i += 2
  elsif a == "--duration-ms" && i + 1 < ARGV.length
    duration_ms = ARGV[i + 1].to_i
    i += 2
  else
    raise "#{USAGE} (unknown argument #{a})"
  end
end

obj = SpinelBPF.load_embedded
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
obj.map_put(Cfg, 0, selftest ? FL.fl_pid : pid)
en = obj.attach_kprobe("on_entry")
ex = obj.attach_kretprobe("on_return")
if selftest
  before = hist_total(obj)
  opened = FL.fl_opens(n)
  after = hist_total(obj)
  en.detach
  ex.detach
  print_hist(obj, "nsecs")
  obj.close
  puts "opens=#{opened} calls=#{after - before}"
  if opened != n || after - before != n
    puts "selftest FAILED: want opens=#{n} calls=#{n}"
    exit 1
  end
  puts "selftest ok"
else
  puts "tracing do_sys_openat2 for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
  en.detach
  ex.detach
  print_hist(obj, "nsecs")
  obj.close
end
