require "bpf"

# opensnoop — openat(2) の path を 1 つずつ印字 (bcc の opensnoop、spinel-ebpf 23fa4b0 tools/opensnoop.rb の移植 — P028 E147)。
# eBPF の側: tracepoint syscalls/sys_enter_openat の filename (const char * — offset 24、8 byte — E142 の :user_str) を ring の event の
# name ([:u8, 64] — 長い path は先頭 63 byte と NUL に切り詰め) に、read_str の status と一緒に。Cfg[0] が 0 でなければその tgid だけ。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Sent = BPF::ArrayMap.new("Sent", :u64, 2)
Ev = Struct.new(:tgid, :pad, :name, :status)
BPF.record(Ev, tgid: :u32, pad: :u32, name: [:u8, 64], status: :i64)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, Array.new(64, 0), 0), 262144)

def on_open(ctx)
  tgid = (BPF.pid_tgid >> 32) & 0xFFFF_FFFF
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      r = Events.output_str(Ev.new(tgid, 0, Array.new(64, 0), 0), :name, ctx.str_field(:filename), :status)
      if r
        Sent.atomic_add(0, 1)
      else
        Sent.atomic_add(1, 1)
      end
    end
  end
end
BPF.tracepoint :on_open, "syscalls/sys_enter_openat", fields: {filename: [24, :user_str]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   opensnoop [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の openat の path を印字
#   opensnoop --selftest                         自分の tgid に絞り、自分が 3 つの path (存在しない path・70 文字の path・/) を openat —
#                                                event がちょうど 3 つで name と status (20・64 (切り詰め)・2) が一致
require "spinelbpf"

# OS は自分の pid と openat(2) を直に (例の中の inline C — path は Ruby の String の memory、自分の process の中)。
module OS
  ffi_source <<~C
    #include <fcntl.h>
    #include <sys/syscall.h>
    #include <unistd.h>
    long os_pid(void) { return (long)getpid(); }
    long os_open(const char *p) { long r = (long)syscall(SYS_openat, AT_FDCWD, p, O_RDONLY); if (r >= 0) close((int)r); return r; }
  C
  ffi_func :os_pid, [], :long
  ffi_func :os_open, [:str], :long
end

# event_fields は read_record の平らな値 [tgid, pad, name[0] … name[63], status] の [tgid, name の文字列 (NUL まで), status]。
def event_fields(v)
  s = ""
  k = 0
  while k < 64 && v[2 + k] != 0
    s += v[2 + k].chr
    k += 1
  end
  [v[0], s, v[66]]
end

USAGE = "usage: opensnoop [--duration-ms MS] [--pid TGID] | --selftest"
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

long = "/nonexistent-e147-" + "x" * 52
paths = ["/nonexistent-e147-a", long, "/"]
obj = SpinelBPF.load_embedded
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
obj.map_put(Cfg, 0, selftest ? OS.os_pid : pid)
r = obj.ringbuf(Events)
l = obj.attach_tracepoint("on_open")
if selftest
  k = 0
  while k < paths.length
    OS.os_open(paths[k])
    k += 1
  end
  obj.map_put(Cfg, 0, 1) # 窓を閉じる (tgid 1 — 自分の後の open を数えない)
else
  puts "tracing openat for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l.detach
puts "    TGID  STATUS  PATH"
names = []
sts = []
v = r.read_record(200)
while v.length > 0
  f = event_fields(v)
  puts "#{f[0].to_s.rjust(8)} #{f[2].to_s.rjust(7)}  #{f[1]}"
  names.push(f[1])
  sts.push(f[2])
  v = r.read_record(200)
end
sent = obj.map_get(Sent, 0)
drops = obj.map_get(Sent, 1)
r.close
obj.close
puts "events=#{names.length} sent=#{sent} drops=#{drops}"
if selftest
  want = [paths[0], long[0, 63], "/"]
  puts "names=#{names.length} status=#{sts.join(",")}"
  if names != want || sts != [20, 64, 2]
    puts "selftest FAILED: want 3 events #{want.join(" ")} with status 20,64,2"
    exit 1
  end
  puts "selftest ok"
end
