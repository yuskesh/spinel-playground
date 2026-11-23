require "bpf"

# syscount — syscall の番号ごとの呼び出しの数 (bcc の syscount、spinel-ebpf 23fa4b0 tools/syscount.rb の移植 — P027 E137)。
# eBPF の側: raw_tp sys_enter の args[1] (syscall の番号) を key に Counts の hash を 1 足す (spinel-ebpf の版は全体の数だけ — bcc の番号ごとに寄せた)。
# Cfg[0] が 0 でなければその tgid だけ。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Counts = BPF::HashMap.new("Counts", :u32, :u64, 1024)
Fails = BPF::ArrayMap.new("Fails", :u64, 1)

def on_enter(ctx)
  tgid = BPF.pid_tgid >> 32
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      if Counts.add_or_init(ctx.arg(1) & 0xFFFF, 1) != 0
        Fails.atomic_add(0, 1)
      end
    end
  end
end
BPF.raw_tp :on_enter, "sys_enter"

# user 空間の側 — 普通の Ruby (Spinel)。
#   syscount [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の syscall の番号ごとの数を多い順に 10 行
#   syscount --selftest                         自分の tgid に絞り getppid (110) を 100 回 — 110 の数の差 = 100 を照らす
require "spinelbpf"

# SC は自分の pid と getppid (例の中の inline C)。
module SC
  ffi_source <<~C
    #include <unistd.h>
    long sc_pid(void) { return (long)getpid(); }
    long sc_getppids(long n) { long s = 0; for (long i = 0; i < n; i++) s += (long)getppid() > 0 ? 1 : 0; return s; }
  C
  ffi_func :sc_pid, [], :long
  ffi_func :sc_getppids, [:long], :long
end

# count_of は Counts の nr の数 (無ければ 0)。
def count_of(obj, nr)
  obj.hash_has(Counts, nr) ? obj.hash_get(Counts, nr) : 0
end

USAGE = "usage: syscount [--duration-ms MS] [--pid TGID] | --selftest"
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
obj.map_put(Cfg, 0, selftest ? SC.sc_pid : pid)
l = obj.attach_raw_tp("on_enter")
if selftest
  before = count_of(obj, 110)
  calls = SC.sc_getppids(100)
  after = count_of(obj, 110)
  l.detach
  obj.close
  puts "getppid calls=#{calls} counted=#{after - before}"
  if calls != 100 || after - before != 100
    puts "selftest FAILED: want calls=100 counted=100"
    exit 1
  end
  puts "selftest ok"
else
  puts "counting syscalls for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
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
  puts "     NR        COUNT"
  k = 0
  while k < rows.length && k < 10
    puts "#{rows[k][1].to_s.rjust(7)} #{rows[k][0].to_s.rjust(12)}"
    k += 1
  end
  puts "syscalls=#{ks.length} fails=#{obj.map_get(Fails, 0)}"
  obj.close
end
