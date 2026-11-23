require "bpf"

# memleak — 解かれていない kmalloc を call_site ごとに集計 (bcc の memleak の kernel の形、spinel-ebpf 23fa4b0 tools/memleak.rb の移植 — P027 E139)。
# **stack の集計ではない — call_site (kmalloc を呼んだ所 — stack の 1 段目) で集計する** (spinel に stack trace の map と get_stackid が無い — i743 (2)、stack は波 2 の候補)。
# eBPF の側: tracepoint kmem/kmalloc で ptr を key に (bytes_alloc・call_site) を Allocs に、kmem/kfree で ptr の entry を消す。
# Cfg[0] が 0 でなければその tgid の割り当てだけを記録する (解放は他の context でも起きるので kfree は絞らない)。
# address (ptr・call_site — kernel の address は 2^63 以上) は下位 63 bit で持つ (Spinel の Integer に入れるため — 上位の bit は kernel の address で常に 1)。
# offset と型は記録した host 7.1.8 の format (testdata/tracefs-7.1.8 — TestBccTracepointFormats が照らす)。
Info = Struct.new(:bytes, :site)
BPF.record(Info, bytes: :u64, site: :u64)
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Allocs = BPF::RecordHashMap.new("Allocs", :u64, Info.new(0, 0), 65536)
Fails = BPF::ArrayMap.new("Fails", :u64, 1)

def on_kmalloc(ctx)
  tgid = BPF.pid_tgid >> 32
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      p = ctx.field(:ptr) & 0x7FFF_FFFF_FFFF_FFFF
      if Allocs.update(p, Info.new(ctx.field(:bytes_alloc) & 0x7FFF_FFFF_FFFF_FFFF, ctx.field(:call_site) & 0x7FFF_FFFF_FFFF_FFFF)) != 0
        Fails.atomic_add(0, 1)
      end
    end
  end
end
BPF.tracepoint :on_kmalloc, "kmem/kmalloc", fields: {call_site: [8, :u64], ptr: [16, :u64], bytes_alloc: [32, :u64]}

def on_kfree(ctx)
  _ = Allocs.delete(ctx.field(:ptr) & 0x7FFF_FFFF_FFFF_FFFF)
end
BPF.tracepoint :on_kfree, "kmem/kfree", fields: {ptr: [16, :u64]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   memleak [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の解かれていない kmalloc を call_site ごとに bytes の多い順に 10 行 (名前は /proc/kallsyms)
#   memleak --selftest                         自分の tgid に絞り socket を 100 個作って閉じずに保ち、1 秒の後に残りの entry > 0 と
#                                              call_site の名前が kallsyms に在ることを照らす (smoke — 自分の socket は process の終わりまで閉じない)
require "spinelbpf"

# ML は自分の pid と閉じない socket (例の中の inline C)。
module ML
  ffi_source <<~C
    #include <sys/socket.h>
    #include <unistd.h>
    long ml_pid(void) { return (long)getpid(); }
    long ml_sockets(long n) { long ok = 0; for (long i = 0; i < n; i++) if (socket(AF_INET, SOCK_DGRAM, 0) >= 0) ok++; return ok; }
  C
  ffi_func :ml_pid, [], :long
  ffi_func :ml_sockets, [:long], :long
end

# hex63 は 16 桁の 16 進の address の下位 63 bit の値 (先頭の桁の上位の bit を外す)。
def hex63(h)
  v = 0
  k = 0
  while k < h.length
    d = h[k].to_i(16)
    d = d & 7 if k == 0 && h.length == 16
    v = v * 16 + d
    k += 1
  end
  v
end

# Kallsyms は /proc/kallsyms の text の symbol (下位 63 bit の address の昇順) — call_site を「関数+offset」に。
class Kallsyms
  def initialize
    @addrs = []
    @names = []
    rows = []
    File.readlines("/proc/kallsyms").each do |l|
      f = l.split(" ")
      if f.length >= 3 && (f[1] == "T" || f[1] == "t")
        rows.push([hex63(f[0]), f[2]])
      end
    end
    rows = rows.sort_by { |r| r[0] }
    rows.each do |r|
      @addrs.push(r[0])
      @names.push(r[1])
    end
  end

  def size
    @addrs.length
  end

  # name は addr を含む symbol (addr 以下で最大の address) の「名前+0xoffset」、無ければ "?"。
  def name(addr)
    lo = 0
    hi = @addrs.length - 1
    best = -1
    while lo <= hi
      mid = (lo + hi) / 2
      if @addrs[mid] <= addr
        best = mid
        lo = mid + 1
      else
        hi = mid - 1
      end
    end
    best < 0 ? "?" : "#{@names[best]}+0x#{(addr - @addrs[best]).to_s(16)}"
  end
end

USAGE = "usage: memleak [--duration-ms MS] [--pid TGID] | --selftest"
selftest = false
pid = 0
duration_ms = 5000
i = 0
while i < ARGV.length
  a = ARGV[i]
  if a == "--selftest"
    selftest = true
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
obj.map_put(Cfg, 0, selftest ? ML.ml_pid : pid)
la = obj.attach_tracepoint("on_kmalloc")
lf = obj.attach_tracepoint("on_kfree")
socks = 0
if selftest
  socks = ML.ml_sockets(100)
  duration_ms = 1000
else
  puts "tracking kmalloc / kfree for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
end
sleep(duration_ms / 1000.0)
la.detach
lf.detach
ks = obj.hash_keys(Allocs)
sites = []
bytes = []
counts = []
k = 0
while k < ks.length
  v = obj.hash_get_record(Allocs, ks[k])
  j = sites.index(v[1])
  if j
    bytes[j] += v[0]
    counts[j] += 1
  else
    sites.push(v[1])
    bytes.push(v[0])
    counts.push(1)
  end
  k += 1
end
order = (0...sites.length).to_a.sort_by { |x| -bytes[x] }
syms = Kallsyms.new
puts "outstanding allocations by call_site (not by stack — call_site is the first frame):"
puts "       BYTES  COUNT  CALL_SITE"
named = 0
k = 0
while k < order.length && k < 10
  x = order[k]
  n = syms.name(sites[x])
  named += 1 if n != "?"
  puts "#{bytes[x].to_s.rjust(12)} #{counts[x].to_s.rjust(6)}  #{n}"
  k += 1
end
fails = obj.map_get(Fails, 0)
obj.close
puts "entries=#{ks.length} sites=#{sites.length} kallsyms=#{syms.size} fails=#{fails}"
if selftest
  puts "sockets=#{socks} named=#{named}"
  if socks != 100 || ks.length <= 0 || named <= 0
    puts "selftest FAILED: want sockets=100 entries > 0 named > 0"
    exit 1
  end
  puts "selftest ok"
end
