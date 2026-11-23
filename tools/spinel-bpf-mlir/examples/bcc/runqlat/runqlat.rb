require "bpf"

# runqlat — run queue の待ちの時間の log2 の histogram (bcc の runqlat、spinel-ebpf 23fa4b0 tools/runqlat.rb の移植 — P027 E133)。
# eBPF の側: sched_wakeup で起こされた task の起床の時刻を Start に、sched_switch で次に走る task の待ち (今 − 起床) を log2 の bucket で Hist に。
# tracepoint の field の offset と型は host 7.1.8 の format (sched_wakeup の pid は 24・sched_switch の next_pid は 56 — load の前に tracefs と照合)。
# Cfg[0] が 0 でなければその tid だけを測る (--pid と selftest)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Start = BPF::HashMap.new("Start", :u32, :u64, 10240)
Hist = BPF::ArrayMap.new("Hist", :u64, 64)

# log2_bucket は v (≥ 0) の 2 を底の対数の整数部 (0 は 0) — bcc の bpf_log2l と同じ bucket。
def log2_bucket(v)
  b = 0
  if v >= 0x1_0000_0000
    b += 32
    v = v >> 32
  end
  if v >= 0x1_0000
    b += 16
    v = v >> 16
  end
  if v >= 0x100
    b += 8
    v = v >> 8
  end
  if v >= 0x10
    b += 4
    v = v >> 4
  end
  if v >= 4
    b += 2
    v = v >> 2
  end
  if v >= 2
    b += 1
  end
  b
end

def on_wakeup(ctx)
  pid = ctx.field(:pid) & 0x7FFF_FFFF
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == pid
      _ = Start.update(pid, BPF.ktime_ns)
    end
  end
end
BPF.tracepoint :on_wakeup, "sched/sched_wakeup", fields: {pid: [24, :i32]}

def on_switch(ctx)
  pid = ctx.field(:next_pid) & 0x7FFF_FFFF
  t = Start.lookup(pid)
  if t
    d = (BPF.ktime_ns & 0x7FFF_FFFF_FFFF_FFFF) - (t.load & 0x7FFF_FFFF_FFFF_FFFF)
    _ = Start.delete(pid)
    if d > 0
      Hist.atomic_add(log2_bucket(d) & 63, 1) # helper の戻り値は呼び手で i64 の全域 (v0.2.0 の制限) — bucket は 0〜63 なので & 63 は値を変えない
    end
  end
end
BPF.tracepoint :on_switch, "sched/sched_switch", fields: {next_pid: [56, :i32]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   runqlat [--duration-ms MS] [--pid TID]   MS の間 (既定 5000) 測り log2 の histogram を印字 (TID を与えればその tid だけ)
#   runqlat --selftest [N]                    自分の tid に絞り usleep(1000) を N 回 (既定 50) — Hist の合計 ≥ N を照らす
require "spinelbpf"

# RQ は自分の tid と usleep (例の中の inline C)。
module RQ
  ffi_source <<~C
    #include <unistd.h>
    #include <sys/syscall.h>
    long rq_tid(void) { return (long)syscall(SYS_gettid); }
    long rq_usleep(long us) { return (long)usleep((useconds_t)us); }
  C
  ffi_func :rq_tid, [], :long
  ffi_func :rq_usleep, [:long], :long
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

USAGE = "usage: runqlat [--duration-ms MS] [--pid TID] | --selftest [N]"
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
if selftest
  obj.map_put(Cfg, 0, RQ.rq_tid)
else
  obj.map_put(Cfg, 0, tid)
end
w = obj.attach_tracepoint("on_wakeup")
s = obj.attach_tracepoint("on_switch")
if selftest
  k = 0
  while k < n
    RQ.rq_usleep(1000)
    k += 1
  end
  w.detach
  s.detach
  total = hist_total(obj)
  print_hist(obj, "nsecs")
  obj.close
  puts "wakeups=#{total}"
  if total < n
    puts "selftest FAILED: want wakeups >= #{n}"
    exit 1
  end
  puts "selftest ok"
else
  puts "tracing run queue latency for #{duration_ms} ms#{tid > 0 ? " (tid #{tid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
  w.detach
  s.detach
  print_hist(obj, "nsecs")
  obj.close
end
