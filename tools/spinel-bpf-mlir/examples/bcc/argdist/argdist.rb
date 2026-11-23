require "bpf"

# argdist — write(2) の count の値ごとの数の表 (bcc の argdist -C 't:syscalls:sys_enter_write():u64:count'、spinel-ebpf 23fa4b0 tools/argdist.rb の移植 — P027 E137)。
# eBPF の側: tracepoint syscalls/sys_enter_write の count を key に Counts の hash を 1 足す。絞りは comm でなく Cfg の tgid (bcc の -p の形 — P027 の問い (1))。
# offset と型は syscalls の event の形 (count は 3 番目の size_t — 32、load の前に tracefs と照合)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Counts = BPF::HashMap.new("Counts", :u64, :u64, 1024)
Fails = BPF::ArrayMap.new("Fails", :u64, 1)

def on_write(ctx)
  tgid = BPF.pid_tgid >> 32
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      if Counts.add_or_init(ctx.field(:count) & 0x7FFF_FFFF_FFFF_FFFF, 1) != 0
        Fails.atomic_add(0, 1)
      end
    end
  end
end
BPF.tracepoint :on_write, "syscalls/sys_enter_write", fields: {count: [32, :u64]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   argdist [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の write(2) の count の値ごとの数を多い順に 10 行
#   argdist --selftest                         自分の tgid に絞り /dev/null に大きさ 100 の write を 7 回と大きさ 200 を 3 回 — key 100 の差 7・200 の差 3 を照らす
require "spinelbpf"

# AD は自分の pid と /dev/null への write (例の中の inline C)。
module AD
  ffi_source <<~C
    #include <fcntl.h>
    #include <unistd.h>
    long ad_pid(void) { return (long)getpid(); }
    long ad_writes(long size, long n) {
      static char buf[4096];
      int fd = open("/dev/null", O_WRONLY); if (fd < 0) return -1;
      long ok = 0; for (long i = 0; i < n; i++) if (write(fd, buf, (size_t)size) == size) ok++;
      close(fd); return ok;
    }
  C
  ffi_func :ad_pid, [], :long
  ffi_func :ad_writes, [:long, :long], :long
end

# count_of は Counts の v の数 (無ければ 0)。
def count_of(obj, v)
  obj.hash_has(Counts, v) ? obj.hash_get(Counts, v) : 0
end

USAGE = "usage: argdist [--duration-ms MS] [--pid TGID] | --selftest"
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
obj.map_put(Cfg, 0, selftest ? AD.ad_pid : pid)
l = obj.attach_tracepoint("on_write")
if selftest
  a0 = count_of(obj, 100)
  b0 = count_of(obj, 200)
  w = AD.ad_writes(100, 7) + AD.ad_writes(200, 3)
  a1 = count_of(obj, 100)
  b1 = count_of(obj, 200)
  l.detach
  obj.close
  puts "writes=#{w} count100=#{a1 - a0} count200=#{b1 - b0}"
  if w != 10 || a1 - a0 != 7 || b1 - b0 != 3
    puts "selftest FAILED: want writes=10 count100=7 count200=3"
    exit 1
  end
  puts "selftest ok"
else
  puts "tabulating write(2) sizes for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
  l.detach
  ks = obj.hash_keys(Counts)
  rows = []
  k = 0
  while k < ks.length
    rows.push([obj.hash_get(Counts, ks[k]), ks[k]])
    k += 1
  end
  rows = rows.sort_by { |r| -r[0] }
  puts "        COUNT  SIZE"
  k = 0
  while k < rows.length && k < 10
    puts "#{rows[k][0].to_s.rjust(12)}  #{rows[k][1]}"
    k += 1
  end
  puts "sizes=#{ks.length} fails=#{obj.map_get(Fails, 0)}"
  obj.close
end
