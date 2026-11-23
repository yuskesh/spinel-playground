require "bpf"

# runqslower — run queue で 1 ms より長く待った起床を 1 つずつ印字 (bcc の runqslower、spinel-ebpf 23fa4b0 tools/runqslower.rb の移植 — P027 E135)。
# eBPF の側: runqlat (E133) と同じ — sched_wakeup で起床の時刻を Start に、sched_switch で次に走る task の待ちが 1 ms を超えた時だけ event (tid・待ち) を ring に。
# offset と型は host 7.1.8 の format (sched_wakeup の pid は 24・sched_switch の next_pid は 56 — load の前に tracefs と照合)。Cfg[0] が 0 でなければその tid だけ。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Start = BPF::HashMap.new("Start", :u32, :u64, 10240)
Drops = BPF::ArrayMap.new("Drops", :u64, 1)
Ev = Struct.new(:tid, :_pad0, :ns)
BPF.record(Ev, tid: :u32, _pad0: :u32, ns: :u64)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0), 65536)

def on_wakeup(ctx)
  pid = ctx.field(:pid) & 0x7FFF_FFFF
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == pid
      _ = Start.update(pid, BPF.ktime_ns)
    end
  end
end
BPF.tracepoint :on_wakeup, "sched/sched_wakeup", fields: {pid: [24, :i32]}

def on_switch(ctx)
  pid = ctx.field(:next_pid) & 0x7FFF_FFFF
  t = Start.lookup(pid)
  if t
    d = (BPF.ktime_ns & 0x7FFF_FFFF_FFFF_FFFF) - (t.load & 0x7FFF_FFFF_FFFF_FFFF)
    _ = Start.delete(pid)
    if d > 1_000_000
      unless Events.output(Ev.new(pid, 0, d))
        Drops.atomic_add(0, 1)
      end
    end
  end
end
BPF.tracepoint :on_switch, "sched/sched_switch", fields: {next_pid: [56, :i32]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   runqslower [--duration-ms MS] [--pid TID]   MS の間 (既定 5000) の 1 ms より長い run queue の待ちを印字
#   runqslower --selftest                        自分の tid に絞り、CPU を埋める thread を CPU の数だけ回しながら usleep(1000) を 200 回 —
#                                                event の数を印字 (1 ms を超える待ちは負荷に依る — smoke、照らすのは rc 0 だけ)
require "spinelbpf"

# RS は自分の tid と、CPU の数の busy な thread の下の usleep (例の中の inline C — pthread)。
module RS
  ffi_source <<~C
    #include <pthread.h>
    #include <sys/syscall.h>
    #include <unistd.h>
    static volatile int rs_stop;
    static void *rs_spin(void *arg) { (void)arg; while (!rs_stop) { } return 0; }
    long rs_tid(void) { return (long)syscall(SYS_gettid); }
    long rs_busy_sleeps(long n) {
      long cpus = sysconf(_SC_NPROCESSORS_ONLN); if (cpus < 1) cpus = 1; if (cpus > 256) cpus = 256;
      pthread_t th[256]; long made = 0; rs_stop = 0;
      for (long i = 0; i < cpus; i++) if (pthread_create(&th[i], 0, rs_spin, 0) == 0) made++;
      for (long i = 0; i < n; i++) usleep(1000);
      rs_stop = 1;
      for (long i = 0; i < made; i++) pthread_join(th[i], 0);
      return made;
    }
  C
  ffi_func :rs_tid, [], :long
  ffi_func :rs_busy_sleeps, [:long], :long
end

USAGE = "usage: runqslower [--duration-ms MS] [--pid TID] | --selftest"
selftest = false
tid = 0
duration_ms = 5000
i = 0
while i < ARGV.length
  a = ARGV[i]
  if a == "--selftest"
    selftest = true
    i += 1
  elsif a == "--pid" && i + 1 < ARGV.length
    tid = ARGV[i + 1].to_i
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
obj.map_put(Cfg, 0, selftest ? RS.rs_tid : tid)
r = obj.ringbuf(Events)
w = obj.attach_tracepoint("on_wakeup")
s = obj.attach_tracepoint("on_switch")
if selftest
  puts "spinners=#{RS.rs_busy_sleeps(200)}"
else
  puts "tracing run queue waits over 1 ms for #{duration_ms} ms#{tid > 0 ? " (tid #{tid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
w.detach
s.detach
puts "     TID      LAT(ns)"
events = 0
v = r.read_record(200)
while v.length > 0
  puts "#{v[0].to_s.rjust(8)} #{v[2].to_s.rjust(12)}"
  events += 1
  v = r.read_record(200)
end
drops = obj.map_get(Drops, 0)
r.close
obj.close
puts "events=#{events} drops=#{drops}"
puts "selftest ok" if selftest
