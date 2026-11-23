require "bpf"

# syncsnoop — sync(2)・fsync(2)・fdatasync(2) を呼んだ tgid を 1 つずつ印字 (bcc の syncsnoop、spinel-ebpf 23fa4b0 tools/syncsnoop.rb の移植 — P027 E136)。
# eBPF の側: tracepoint syscalls/sys_enter_sync・sys_enter_fsync・sys_enter_fdatasync を、tgid と種類 (1 = sync・2 = fsync・3 = fdatasync) と一緒に ring に。
# Cfg[0] が 0 でなければその tgid だけ。offset と型は syscalls の event の形 (sync は引数が無いので __syscall_nr を宣言 — tracepoint の宣言は field を 1 つ以上要る)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Drops = BPF::ArrayMap.new("Drops", :u64, 1)
Ev = Struct.new(:tgid, :kind)
BPF.record(Ev, tgid: :u32, kind: :u32)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0), 65536)

# emit は kind の event を ring に (Cfg の tgid の絞り)。
def emit(kind)
  tgid = BPF.pid_tgid >> 32
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      unless Events.output(Ev.new(tgid, kind))
        Drops.atomic_add(0, 1)
      end
    end
  end
  0
end

def on_sync(ctx)
  _ = emit(1)
end
BPF.tracepoint :on_sync, "syscalls/sys_enter_sync", fields: {__syscall_nr: [8, :i32]}

def on_fsync(ctx)
  _ = emit(2)
end
BPF.tracepoint :on_fsync, "syscalls/sys_enter_fsync", fields: {fd: [16, :u64]}

def on_fdatasync(ctx)
  _ = emit(3)
end
BPF.tracepoint :on_fdatasync, "syscalls/sys_enter_fdatasync", fields: {fd: [16, :u64]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   syncsnoop [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の sync / fsync / fdatasync を印字
#   syncsnoop --selftest                         自分の tgid に絞り sync を 1 回・fsync を 3 回・fdatasync を 2 回 — 種類ごとに 1 / 3 / 2 を照らす
require "spinelbpf"

# SY は自分の pid と sync / fsync / fdatasync (例の中の inline C — fsync の file は build/tmp の下の一時の file)。
module SY
  ffi_source <<~C
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>
    long sy_pid(void) { return (long)getpid(); }
    long sy_calls(void) {
      char p[] = "/tmp/syncsnoop-XXXXXX";
      const char *d = getenv("TMPDIR");
      char buf[4096];
      int fd;
      if (d && *d) {
        int n = snprintf(buf, sizeof buf, "%s/syncsnoop-XXXXXX", d);
        if (n <= 0 || n >= (int)sizeof buf) return -1;
        fd = mkstemp(buf);
        if (fd >= 0) unlink(buf);
      } else {
        fd = mkstemp(p);
        if (fd >= 0) unlink(p);
      }
      if (fd < 0) return -1;
      long ok = 0;
      sync(); ok++;
      for (int i = 0; i < 3; i++) if (fsync(fd) == 0) ok++;
      for (int i = 0; i < 2; i++) if (fdatasync(fd) == 0) ok++;
      close(fd);
      return ok;
    }
  C
  ffi_func :sy_pid, [], :long
  ffi_func :sy_calls, [], :long
end

USAGE = "usage: syncsnoop [--duration-ms MS] [--pid TGID] | --selftest"
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
obj.map_put(Cfg, 0, selftest ? SY.sy_pid : pid)
r = obj.ringbuf(Events)
l1 = obj.attach_tracepoint("on_sync")
l2 = obj.attach_tracepoint("on_fsync")
l3 = obj.attach_tracepoint("on_fdatasync")
calls = 0
if selftest
  calls = SY.sy_calls
else
  puts "tracing sync / fsync / fdatasync for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l1.detach
l2.detach
l3.detach
puts "    TGID  CALL"
n = [0, 0, 0, 0]
names = ["", "sync", "fsync", "fdatasync"]
v = r.read_record(200)
while v.length > 0
  k = v[1]
  if k >= 1 && k <= 3
    puts "#{v[0].to_s.rjust(8)}  #{names[k]}"
    n[k] += 1
  end
  v = r.read_record(200)
end
drops = obj.map_get(Drops, 0)
r.close
obj.close
puts "sync=#{n[1]} fsync=#{n[2]} fdatasync=#{n[3]} drops=#{drops}"
if selftest
  puts "calls=#{calls}"
  if calls != 6 || n[1] != 1 || n[2] != 3 || n[3] != 2
    puts "selftest FAILED: want calls=6 sync=1 fsync=3 fdatasync=2"
    exit 1
  end
  puts "selftest ok"
end
