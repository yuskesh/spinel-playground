require "bpf"

# hardirqs — hard IRQ の handler の時間の log2 の histogram (bcc の hardirqs、spinel-ebpf 23fa4b0 tools/hardirqs.rb の移植 — P027 E134)。
# eBPF の側: irq_handler_entry で始まりの時刻を CPU ごとの slot (Start — per-CPU の配列の slot 0) に、irq_handler_exit で差を Hist に。
# handler は 1 つの CPU で終わるので CPU ごとの slot で衝突しない (spinel-ebpf の cpu_id の key と同じ意味 — cpu id の helper は使わない)。
# offset と型は host 7.1.8 の format (entry / exit の irq は 8 — load の前に tracefs と照合)。
Start = BPF::PerCpuArrayMap.new("Start", :u64, 1)
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
  Start.update(0, BPF.ktime_ns)
end
BPF.tracepoint :on_entry, "irq/irq_handler_entry", fields: {irq: [8, :i32]}

def on_exit(ctx)
  t = Start.lookup(0)
  if t
    s = t.load & 0x7FFF_FFFF_FFFF_FFFF
    if s > 0
      d = (BPF.ktime_ns & 0x7FFF_FFFF_FFFF_FFFF) - s
      Start.update(0, 0)
      if d > 0
        Hist.atomic_add(log2_bucket(d) & 63, 1) # bucket は 0〜63 — & 63 は値を変えない (helper の戻り値は i64 の全域)
      end
    end
  end
end
BPF.tracepoint :on_exit, "irq/irq_handler_exit", fields: {irq: [8, :i32]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   hardirqs [--duration-ms MS]   MS の間 (既定 5000) 測り log2 の histogram を印字 (system 全体)
#   hardirqs --selftest           1 秒の後に Hist の合計 > 0 を照らす (割り込みは自分に帰せない — smoke)
require "spinelbpf"

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

USAGE = "usage: hardirqs [--duration-ms MS] | --selftest"
selftest = false
duration_ms = 5000
i = 0
while i < ARGV.length
  a = ARGV[i]
  if a == "--selftest"
    selftest = true
    i += 1
  elsif a == "--duration-ms" && i + 1 < ARGV.length
    duration_ms = ARGV[i + 1].to_i
    i += 2
  else
    raise "#{USAGE} (unknown argument #{a})"
  end
end

obj = SpinelBPF.load_embedded
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
en = obj.attach_tracepoint("on_entry")
ex = obj.attach_tracepoint("on_exit")
if selftest
  duration_ms = 1000
else
  puts "tracing hard IRQ handler time for #{duration_ms} ms"
  $stdout.flush
end
sleep(duration_ms / 1000.0)
en.detach
ex.detach
total = hist_total(obj)
print_hist(obj, "nsecs")
obj.close
if selftest
  puts "handlers=#{total}"
  if total <= 0
    puts "selftest FAILED: want handlers > 0"
    exit 1
  end
  puts "selftest ok"
end
