require "bpf"

# cachestat — page cache の hit / miss の数 (bcc の cachestat、spinel-ebpf 23fa4b0 tools/cachestat.rb の移植 — P027 E137)。
# eBPF の側: kprobe folio_mark_accessed (access)・filemap_add_folio (miss)・mark_buffer_dirty (dirty) で Events の key 0 / 1 / 2 を 1 足す。
# hits = accesses − misses (bcc の近似と同じ)。Cfg[0] が 0 でなければその tgid だけ。params は kprobe の宣言に要る 1 つ (読まない)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Events = BPF::HashMap.new("Events", :u32, :u64, 4)
Fails = BPF::ArrayMap.new("Fails", :u64, 1)

# count は今の tgid が Cfg の絞りに入れば Events の k を 1 足す。
def count(k)
  tgid = BPF.pid_tgid >> 32
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      if Events.add_or_init(k, 1) != 0
        Fails.atomic_add(0, 1)
      end
    end
  end
  0
end

def on_access(ctx)
  _ = count(0)
end
BPF.kprobe :on_access, "folio_mark_accessed", params: {1 => :ptr}

def on_miss(ctx)
  _ = count(1)
end
BPF.kprobe :on_miss, "filemap_add_folio", params: {3 => :u64}

def on_dirty(ctx)
  _ = count(2)
end
BPF.kprobe :on_dirty, "mark_buffer_dirty", params: {1 => :ptr}

# user 空間の側 — 普通の Ruby (Spinel)。
#   cachestat [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の accesses・misses・dirties・hits・hit の比
#   cachestat --selftest                         自分の tgid に絞り TMPDIR の下の 4 MB の file を書いて 2 回読む — accesses の差 > 0 を照らす (smoke)
require "spinelbpf"

# CS は自分の pid と一時の file の書きと読み (例の中の inline C)。
module CS
  ffi_source <<~C
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>
    long cs_pid(void) { return (long)getpid(); }
    long cs_io(long mb) {
      static char buf[65536];
      char p[4096]; const char *d = getenv("TMPDIR");
      int k = snprintf(p, sizeof p, "%s/cachestat-%ld", (d && *d) ? d : "/tmp", (long)getpid());
      if (k <= 0 || k >= (int)sizeof p) return -1;
      int fd = open(p, O_RDWR | O_CREAT | O_TRUNC, 0600); if (fd < 0) return -1;
      long done = 0;
      for (long i = 0; i < mb * 16; i++) if (write(fd, buf, sizeof buf) == (ssize_t)sizeof buf) done++;
      for (int r = 0; r < 2; r++) { lseek(fd, 0, SEEK_SET); while (read(fd, buf, sizeof buf) > 0) done++; }
      close(fd); unlink(p);
      return done;
    }
  C
  ffi_func :cs_pid, [], :long
  ffi_func :cs_io, [:long], :long
end

# count_of は Events の k の数 (無ければ 0)。
def count_of(obj, k)
  obj.hash_has(Events, k) ? obj.hash_get(Events, k) : 0
end

USAGE = "usage: cachestat [--duration-ms MS] [--pid TGID] | --selftest"
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
obj.map_put(Cfg, 0, selftest ? CS.cs_pid : pid)
la = obj.attach_kprobe("on_access")
lm = obj.attach_kprobe("on_miss")
ld = obj.attach_kprobe("on_dirty")
a0 = count_of(obj, 0)
if selftest
  puts "io=#{CS.cs_io(4)}"
else
  puts "counting page cache events for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
la.detach
lm.detach
ld.detach
acc = count_of(obj, 0)
miss = count_of(obj, 1)
dirty = count_of(obj, 2)
hits = acc - miss
hits = 0 if hits < 0
ratio = acc > 0 ? hits * 100 / acc : 0
puts "accesses=#{acc} misses=#{miss} dirties=#{dirty} hits=#{hits} ratio=#{ratio}% fails=#{obj.map_get(Fails, 0)}"
obj.close
if selftest
  puts "access_delta=#{acc - a0}"
  if acc - a0 <= 0
    puts "selftest FAILED: want access_delta > 0"
    exit 1
  end
  puts "selftest ok"
end
