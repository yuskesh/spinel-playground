require "bpf"

# funccount — kernel の関数 (do_sys_openat2) の呼び出しの数 (bcc の funccount、spinel-ebpf 23fa4b0 tools/funccount.rb の移植 — P027 E137)。
# eBPF の側: kprobe で Calls を 1 足す。Cfg[0] が 0 でなければその tgid だけ。他の関数を数えるには宣言の関数の名前を替える (params は宣言に要る 1 つ — 読まない)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Calls = BPF::Counter.new("Calls", :u64)

def on_call(ctx)
  tgid = BPF.pid_tgid >> 32
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      Calls.add(1)
    end
  end
end
BPF.kprobe :on_call, "do_sys_openat2", params: {1 => :i32}

# user 空間の側 — 普通の Ruby (Spinel)。
#   funccount [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の do_sys_openat2 の呼び出しの数
#   funccount --selftest                         自分の tgid に絞り open("/dev/null") を 50 回 — 数の差 = 50 を照らす
require "spinelbpf"

# FC は自分の pid と open / close (例の中の inline C)。
module FC
  ffi_source <<~C
    #include <fcntl.h>
    #include <unistd.h>
    long fc_pid(void) { return (long)getpid(); }
    long fc_opens(long n) { long ok = 0; for (long i = 0; i < n; i++) { int fd = open("/dev/null", O_RDONLY); if (fd >= 0) { ok++; close(fd); } } return ok; }
  C
  ffi_func :fc_pid, [], :long
  ffi_func :fc_opens, [:long], :long
end

USAGE = "usage: funccount [--duration-ms MS] [--pid TGID] | --selftest"
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
obj.map_put(Cfg, 0, selftest ? FC.fc_pid : pid)
l = obj.attach_kprobe("on_call")
if selftest
  before = obj.counter_get(Calls)
  opens = FC.fc_opens(50)
  after = obj.counter_get(Calls)
  l.detach
  obj.close
  puts "opens=#{opens} calls=#{after - before}"
  if opens != 50 || after - before != 50
    puts "selftest FAILED: want opens=50 calls=50"
    exit 1
  end
  puts "selftest ok"
else
  puts "counting do_sys_openat2 for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
  l.detach
  puts "calls=#{obj.counter_get(Calls)}"
  obj.close
end
