require "bpf"

# fileslower — 1 ms より遅い vfs_read を 1 つずつ印字 (bcc の fileslower、spinel-ebpf 23fa4b0 tools/fileslower.rb の移植 — P027 E135)。
# eBPF の側: kprobe vfs_read で入りの時刻を thread (pid_tgid) の key で Start に、kretprobe で差が 1 ms を超えた時だけ event (tgid・tid・差・戻り値) を ring に。
# Cfg[0] が 0 でなければその tgid だけ。params は kprobe の宣言に要る 1 つ (count — 読まない)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Start = BPF::HashMap.new("Start", :u64, :u64, 10240)
Drops = BPF::ArrayMap.new("Drops", :u64, 1)
Ev = Struct.new(:tgid, :tid, :ns, :ret)
BPF.record(Ev, tgid: :u32, tid: :u32, ns: :u64, ret: :i64)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0, 0), 65536)

def on_entry(ctx)
  id = BPF.pid_tgid & 0x7FFF_FFFF_FFFF_FFFF
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == (id >> 32)
      _ = Start.update(id, BPF.ktime_ns)
    end
  end
end
BPF.kprobe :on_entry, "vfs_read", params: {3 => :u64}

def on_return(ctx)
  id = BPF.pid_tgid & 0x7FFF_FFFF_FFFF_FFFF
  t = Start.lookup(id)
  if t
    d = (BPF.ktime_ns & 0x7FFF_FFFF_FFFF_FFFF) - (t.load & 0x7FFF_FFFF_FFFF_FFFF)
    _ = Start.delete(id)
    if d > 1_000_000
      unless Events.output(Ev.new(id >> 32, id & 0xFFFF_FFFF, d, ctx.ret))
        Drops.atomic_add(0, 1)
      end
    end
  end
end
BPF.kretprobe :on_return, "vfs_read", ret: :i64

# user 空間の側 — 普通の Ruby (Spinel)。
#   fileslower [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の 1 ms より遅い vfs_read を印字
#   fileslower --selftest                         自分の tgid に絞り、pipe の read を 5 回 (書き手の thread が 5 ms 待つ) と待たない read を 5 回 —
#                                                 event はちょうど 5 つで各差 ≥ 1 ms を照らす
require "spinelbpf"

# FS は自分の pid と pipe の遅い read と速い read (例の中の inline C — 書き手は pthread)。
module FS
  ffi_source <<~C
    #include <pthread.h>
    #include <time.h>
    #include <unistd.h>
    static int fs_p[2];
    static void *fs_writer(void *arg) {
      long n = (long)arg; char c = 'x';
      for (long i = 0; i < n; i++) { struct timespec t = {0, 5000000}; nanosleep(&t, 0); if (write(fs_p[1], &c, 1) != 1) break; }
      return 0;
    }
    long fs_pid(void) { return (long)getpid(); }
    long fs_reads(long slow, long fast) {
      if (pipe(fs_p) < 0) return -1;
      pthread_t th; char c; long ok = 0;
      if (pthread_create(&th, 0, fs_writer, (void *)slow) != 0) return -1;
      for (long i = 0; i < slow; i++) if (read(fs_p[0], &c, 1) == 1) ok++;
      pthread_join(th, 0);
      for (long i = 0; i < fast; i++) { if (write(fs_p[1], &c, 1) == 1 && read(fs_p[0], &c, 1) == 1) ok++; }
      close(fs_p[0]); close(fs_p[1]);
      return ok;
    }
  C
  ffi_func :fs_pid, [], :long
  ffi_func :fs_reads, [:long, :long], :long
end

USAGE = "usage: fileslower [--duration-ms MS] [--pid TGID] | --selftest"
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
obj.map_put(Cfg, 0, selftest ? FS.fs_pid : pid)
r = obj.ringbuf(Events)
en = obj.attach_kprobe("on_entry")
ex = obj.attach_kretprobe("on_return")
if selftest
  reads = FS.fs_reads(5, 5)
else
  puts "tracing vfs_read slower than 1 ms for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
en.detach
ex.detach
puts "    TGID      TID        LAT(ns)  RET"
events = 0
slow = 0
v = r.read_record(200)
while v.length > 0
  puts "#{v[0].to_s.rjust(8)} #{v[1].to_s.rjust(8)} #{v[2].to_s.rjust(14)}  #{v[3]}"
  events += 1
  slow += 1 if v[2] >= 1_000_000
  v = r.read_record(200)
end
drops = obj.map_get(Drops, 0)
r.close
obj.close
puts "events=#{events} drops=#{drops}"
if selftest
  puts "reads=#{reads}"
  if reads != 10 || events != 5 || slow != 5
    puts "selftest FAILED: want reads=10 events=5 (all >= 1 ms)"
    exit 1
  end
  puts "selftest ok"
end
