require "bpf"

# slabratetop — slab の object の割り当ての数と大きさの log2 の histogram (bcc の slabratetop、spinel-ebpf 23fa4b0 tools/slabratetop.rb の移植 — P027 E134)。
# eBPF の側: kmem_cache_alloc ごとに Allocs を 1 足し、bytes_alloc の log2 の bucket を Hist に。cache の名前 (__data_loc の文字列) は出さない (spinel-ebpf と同じ)。
# offset と型は host 7.1.8 の format (bytes_alloc は 40 の size_t — load の前に tracefs と照合)。
Allocs = BPF::Counter.new("Allocs", :u64)
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

def on_alloc(ctx)
  Allocs.add(1)
  v = ctx.field(:bytes_alloc) & 0x7FFF_FFFF_FFFF_FFFF
  Hist.atomic_add(log2_bucket(v) & 63, 1) # bucket は 0〜63 — & 63 は値を変えない (helper の戻り値は i64 の全域)
end
BPF.tracepoint :on_alloc, "kmem/kmem_cache_alloc", fields: {bytes_alloc: [40, :u64]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   slabratetop [--duration-ms MS]   MS の間 (既定 5000) の割り当ての数・率と大きさの histogram を印字 (system 全体)
#   slabratetop --selftest           自分が socket の作成と close を 100 回した後に Allocs > 0 かつ Hist の合計 = Allocs を照らす (smoke)
require "spinelbpf"

# SL は socket の作成と close (例の中の inline C)。
module SL
  ffi_source <<~C
    #include <sys/socket.h>
    #include <unistd.h>
    long sl_sockets(long n) {
      long ok = 0;
      for (long i = 0; i < n; i++) { int s = socket(AF_INET, SOCK_DGRAM, 0); if (s >= 0) { ok++; close(s); } }
      return ok;
    }
  C
  ffi_func :sl_sockets, [:long], :long
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

USAGE = "usage: slabratetop [--duration-ms MS] | --selftest"
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
l = obj.attach_tracepoint("on_alloc")
if selftest
  puts "sockets=#{SL.sl_sockets(100)}"
else
  puts "tracing kmem_cache_alloc for #{duration_ms} ms"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l.detach
allocs = obj.counter_get(Allocs)
total = hist_total(obj)
print_hist(obj, "bytes")
obj.close
if selftest
  puts "allocs=#{allocs} hist=#{total}"
  if allocs <= 0 || total != allocs
    puts "selftest FAILED: want allocs > 0 and hist == allocs"
    exit 1
  end
  puts "selftest ok"
else
  puts "allocs=#{allocs} (#{allocs * 1000 / (duration_ms > 0 ? duration_ms : 1)}/s)"
end
