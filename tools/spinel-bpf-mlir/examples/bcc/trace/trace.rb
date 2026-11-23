require "bpf"

# trace — 1 つの process の openat(2) の path だけを印字 (bcc の trace の `-p PID` の絞り、spinel-ebpf 23fa4b0 tools/trace.rb の移植 — P028 E147)。
# spinel-ebpf の trace は comm "trycat" で絞る — この移植は bcc の trace の `-p` と同じ **pid (tgid) の絞り** (P028 §2)。
# eBPF の側: tracepoint syscalls/sys_enter_openat の filename (E142 の :user_str) を、Cfg[0] の tgid のときだけ ring の event に (絞りは kernel の中)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Sent = BPF::ArrayMap.new("Sent", :u64, 2)
Ev = Struct.new(:tgid, :pad, :name, :status)
BPF.record(Ev, tgid: :u32, pad: :u32, name: [:u8, 64], status: :i64)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, Array.new(64, 0), 0), 65536)

def on_open(ctx)
  tgid = (BPF.pid_tgid >> 32) & 0xFFFF_FFFF
  c = Cfg.lookup(0)
  if c
    if c.load == tgid
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
#   trace --pid TGID [--duration-ms MS]   MS の間 (既定 5000) の TGID の openat の path を印字 (--pid は必須 — 絞りの無い trace は opensnoop)
#   trace --selftest                       --pid に自分の tgid — 自分の openat の path 2 つが出て、子の process (fork して別の path を openat) の event は 0
require "spinelbpf"

# TR は自分の pid・openat(2) を直に・子が別の path を openat して終わる fork (例の中の inline C — 子の path は fork の前に親の stack に写す)。
module TR
  ffi_source <<~C
    #include <fcntl.h>
    #include <string.h>
    #include <sys/syscall.h>
    #include <sys/types.h>
    #include <sys/wait.h>
    #include <unistd.h>
    long tr_pid(void) { return (long)getpid(); }
    long tr_open(const char *p) { long r = (long)syscall(SYS_openat, AT_FDCWD, p, O_RDONLY); if (r >= 0) close((int)r); return r; }
    long tr_child_open(void) {
      char p[32];
      strcpy(p, "/nonexistent-e147-child");
      pid_t c = fork();
      if (c == 0) { syscall(SYS_openat, AT_FDCWD, p, O_RDONLY); _exit(0); }
      if (c < 0) return -1;
      int st; waitpid(c, &st, 0);
      return (long)c;
    }
  C
  ffi_func :tr_pid, [], :long
  ffi_func :tr_open, [:str], :long
  ffi_func :tr_child_open, [], :long
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

USAGE = "usage: trace --pid TGID [--duration-ms MS] | --selftest"
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
pid = TR.tr_pid if selftest
if pid <= 0
  raise "#{USAGE} (--pid is required — without a filter, use opensnoop)"
end

obj = SpinelBPF.load_embedded
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
obj.map_put(Cfg, 0, pid)
r = obj.ringbuf(Events)
l = obj.attach_tracepoint("on_open")
child = 0
if selftest
  TR.tr_open("/nonexistent-e147-t1")
  TR.tr_open("/nonexistent-e147-t2")
  child = TR.tr_child_open
  obj.map_put(Cfg, 0, 1) # 窓を閉じる (tgid 1)
else
  puts "tracing openat of tgid #{pid} for #{duration_ms} ms"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l.detach
puts "    TGID  STATUS  PATH"
names = []
others = 0
v = r.read_record(200)
while v.length > 0
  f = event_fields(v)
  puts "#{f[0].to_s.rjust(8)} #{f[2].to_s.rjust(7)}  #{f[1]}"
  if f[0] == pid
    names.push(f[1])
  else
    others += 1
  end
  v = r.read_record(200)
end
r.close
obj.close
puts "events=#{names.length} others=#{others}"
if selftest
  puts "child=#{child} names=#{names.join(" ")}"
  if names != ["/nonexistent-e147-t1", "/nonexistent-e147-t2"] || others != 0 || child <= 0
    puts "selftest FAILED: want only this process's two opens (/nonexistent-e147-t1 /nonexistent-e147-t2) and no event from the child"
    exit 1
  end
  puts "selftest ok"
end
