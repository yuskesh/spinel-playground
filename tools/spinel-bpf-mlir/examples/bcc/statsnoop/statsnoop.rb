require "bpf"

# statsnoop — stat(2) の族 (newfstatat・statx) の path を 1 つずつ印字 (bcc の statsnoop、spinel-ebpf 23fa4b0 tools/statsnoop.rb の移植 — P028 E147)。
# eBPF の側: tracepoint syscalls/sys_enter_newfstatat と sys_enter_statx の filename (どちらも const char * — offset 24 — E142 の :user_str) を
# 種類 (1 = newfstatat・2 = statx) と一緒に ring の event に。今の glibc の stat() はこの 2 つを通る。Cfg[0] が 0 でなければその tgid だけ。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Sent = BPF::ArrayMap.new("Sent", :u64, 2)
Ev = Struct.new(:tgid, :kind, :name, :status)
BPF.record(Ev, tgid: :u32, kind: :u32, name: [:u8, 64], status: :i64)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, Array.new(64, 0), 0), 262144)

def on_fstatat(ctx)
  tgid = (BPF.pid_tgid >> 32) & 0xFFFF_FFFF
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      r = Events.output_str(Ev.new(tgid, 1, Array.new(64, 0), 0), :name, ctx.str_field(:filename), :status)
      if r
        Sent.atomic_add(0, 1)
      else
        Sent.atomic_add(1, 1)
      end
    end
  end
end
BPF.tracepoint :on_fstatat, "syscalls/sys_enter_newfstatat", fields: {filename: [24, :user_str]}

def on_statx(ctx)
  tgid = (BPF.pid_tgid >> 32) & 0xFFFF_FFFF
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      r = Events.output_str(Ev.new(tgid, 2, Array.new(64, 0), 0), :name, ctx.str_field(:filename), :status)
      if r
        Sent.atomic_add(0, 1)
      else
        Sent.atomic_add(1, 1)
      end
    end
  end
end
BPF.tracepoint :on_statx, "syscalls/sys_enter_statx", fields: {filename: [24, :user_str]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   statsnoop [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の newfstatat / statx の path を印字
#   statsnoop --selftest                         自分の tgid に絞り、自分が newfstatat("/") と statx("/nonexistent-e147-s") を 1 回ずつ —
#                                                種類 1 と 2 の event がちょうど 1 つずつで name と status (2・20) が一致
require "spinelbpf"

# SS は自分の pid と newfstatat(2)・statx(2) を直に (例の中の inline C — path は Ruby の String の memory、自分の process の中)。
module SS
  ffi_source <<~C
    #include <fcntl.h>
    #include <sys/stat.h>
    #include <sys/syscall.h>
    #include <unistd.h>
    #include <linux/stat.h>
    long ss_pid(void) { return (long)getpid(); }
    long ss_fstatat(const char *p) { struct stat st; return (long)syscall(SYS_newfstatat, AT_FDCWD, p, &st, 0); }
    long ss_statx(const char *p) { struct statx sx; return (long)syscall(SYS_statx, AT_FDCWD, p, 0, STATX_BASIC_STATS, &sx); }
  C
  ffi_func :ss_pid, [], :long
  ffi_func :ss_fstatat, [:str], :long
  ffi_func :ss_statx, [:str], :long
end

# event_fields は read_record の平らな値 [tgid, kind, name[0] … name[63], status] の [tgid, kind, name の文字列 (NUL まで), status]。
def event_fields(v)
  s = ""
  k = 0
  while k < 64 && v[2 + k] != 0
    s += v[2 + k].chr
    k += 1
  end
  [v[0], v[1], s, v[66]]
end

USAGE = "usage: statsnoop [--duration-ms MS] [--pid TGID] | --selftest"
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
obj.map_put(Cfg, 0, selftest ? SS.ss_pid : pid)
r = obj.ringbuf(Events)
l1 = obj.attach_tracepoint("on_fstatat")
l2 = obj.attach_tracepoint("on_statx")
if selftest
  SS.ss_fstatat("/")
  SS.ss_statx("/nonexistent-e147-s")
  obj.map_put(Cfg, 0, 1) # 窓を閉じる (tgid 1)
else
  puts "tracing newfstatat / statx for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l1.detach
l2.detach
puts "    TGID  CALL         STATUS  PATH"
got = []
v = r.read_record(200)
while v.length > 0
  f = event_fields(v)
  puts "#{f[0].to_s.rjust(8)}  #{f[1] == 1 ? "newfstatat" : "statx     "} #{f[3].to_s.rjust(6)}  #{f[2]}"
  got.push("#{f[1]}:#{f[2]}:#{f[3]}")
  v = r.read_record(200)
end
sent = obj.map_get(Sent, 0)
drops = obj.map_get(Sent, 1)
r.close
obj.close
puts "events=#{got.length} sent=#{sent} drops=#{drops}"
if selftest
  want = "1:/:2 2:/nonexistent-e147-s:20"
  puts "sequence=#{got.join(" ")}"
  if got.join(" ") != want
    puts "selftest FAILED: want #{want} (kind:path:status)"
    exit 1
  end
  puts "selftest ok"
end
