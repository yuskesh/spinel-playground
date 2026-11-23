require "bpf"

# cpudist — task が CPU の上で続けて走った時間 (scheduling の 1 区切り) の log2 の histogram (bcc の cpudist、spinel-ebpf 23fa4b0 tools/cpudist.rb の移植 — P027 E134)。
# eBPF の側: sched_switch で出る task (prev_pid) の走り始め (Start) からの時間を Hist に、入る task (next_pid) の走り始めを Start に。
# offset と型は host 7.1.8 の format (prev_pid は 24・next_pid は 56 — load の前に tracefs と照合)。Cfg[0] が 0 でなければその tid だけ。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Start = BPF::HashMap.new("Start", :u32, :u64, 10240)
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

def on_switch(ctx)
  prev = ctx.field(:prev_pid) & 0x7FFF_FFFF
  nxt = ctx.field(:next_pid) & 0x7FFF_FFFF
  c = Cfg.lookup(0)
  if c
    want = c.load
    if want == 0 || want == prev
      t = Start.lookup(prev)
      if t
        d = (BPF.ktime_ns & 0x7FFF_FFFF_FFFF_FFFF) - (t.load & 0x7FFF_FFFF_FFFF_FFFF)
        _ = Start.delete(prev)
        if d > 0
          Hist.atomic_add(log2_bucket(d) & 63, 1) # bucket は 0〜63 — & 63 は値を変えない (helper の戻り値は i64 の全域)
        end
      end
    end
    if want == 0 || want == nxt
      _ = Start.update(nxt, BPF.ktime_ns)
    end
  end
end
BPF.tracepoint :on_switch, "sched/sched_switch", fields: {prev_pid: [24, :i32], next_pid: [56, :i32]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   cpudist [--duration-ms MS] [--pid TID]   MS の間 (既定 5000) 測り log2 の histogram を印字
#   cpudist --selftest [N]                    自分の tid に絞り usleep(1000) を N 回 (既定 50) — Hist の合計 > 0 を照らす
require "spinelbpf"

# CD は自分の tid と usleep (例の中の inline C)。
module CD
  ffi_source <<~C
    #include <unistd.h>
    #include <sys/syscall.h>
    long cd_tid(void) { return (long)syscall(SYS_gettid); }
    long cd_usleep(long us) { return (long)usleep((useconds_t)us); }
  C
  ffi_func :cd_tid, [], :long
  ffi_func :cd_usleep, [:long], :long
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

USAGE = "usage: cpudist [--duration-ms MS] [--pid TID] | --selftest [N]"
selftest = false
n = 50
tid = 0
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
    tid = ARGV[i + 1].to_i
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
obj.map_put(Cfg, 0, selftest ? CD.cd_tid : tid)
s = obj.attach_tracepoint("on_switch")
if selftest
  k = 0
  while k < n
    CD.cd_usleep(1000)
    k += 1
  end
  s.detach
  total = hist_total(obj)
  print_hist(obj, "nsecs")
  obj.close
  puts "slices=#{total}"
  if total <= 0
    puts "selftest FAILED: want slices > 0"
    exit 1
  end
  puts "selftest ok"
else
  puts "tracing on-CPU time for #{duration_ms} ms#{tid > 0 ? " (tid #{tid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
  s.detach
  print_hist(obj, "nsecs")
  obj.close
end
