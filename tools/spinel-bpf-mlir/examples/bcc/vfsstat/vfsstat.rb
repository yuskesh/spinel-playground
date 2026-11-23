require "bpf"

# vfsstat — VFS の read / write / open の数 (bcc の vfsstat、spinel-ebpf 23fa4b0 tools/vfsstat.rb の移植 — P027 E137)。
# eBPF の側: kprobe vfs_read・vfs_write・vfs_open で Reads・Writes・Opens を 1 足す。Cfg[0] が 0 でなければその tgid だけ。
# params は kprobe の宣言に要る 1 つ (読まない — vfs_read / vfs_write の count、vfs_open の path の pointer)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Reads = BPF::Counter.new("Reads", :u64)
Writes = BPF::Counter.new("Writes", :u64)
Opens = BPF::Counter.new("Opens", :u64)

# mine は今の tgid が Cfg の絞りに入るか。
def mine
  tgid = BPF.pid_tgid >> 32
  r = 0
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      r = 1
    end
  end
  r
end

def on_read(ctx)
  if mine == 1
    Reads.add(1)
  end
end
BPF.kprobe :on_read, "vfs_read", params: {3 => :u64}

def on_write(ctx)
  if mine == 1
    Writes.add(1)
  end
end
BPF.kprobe :on_write, "vfs_write", params: {3 => :u64}

def on_open(ctx)
  if mine == 1
    Opens.add(1)
  end
end
BPF.kprobe :on_open, "vfs_open", params: {1 => :ptr}

# user 空間の側 — 普通の Ruby (Spinel)。
#   vfsstat [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の vfs_read / vfs_write / vfs_open の数
#   vfsstat --selftest                         自分の tgid に絞り TMPDIR の下の file の open を 10 回・read を 20 回・write を 30 回 — 差が 10 / 20 / 30 を照らす
require "spinelbpf"

# VS は自分の pid と一時の file の open / read / write (例の中の inline C)。
module VS
  ffi_source <<~C
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>
    static int vs_fd = -1;
    static char vs_path[4096];
    long vs_pid(void) { return (long)getpid(); }
    long vs_prepare(void) {
      const char *d = getenv("TMPDIR");
      int k = snprintf(vs_path, sizeof vs_path, "%s/vfsstat-%ld", (d && *d) ? d : "/tmp", (long)getpid());
      if (k <= 0 || k >= (int)sizeof vs_path) return -1;
      vs_fd = open(vs_path, O_RDWR | O_CREAT | O_TRUNC, 0600);
      return vs_fd < 0 ? -1 : 0;
    }
    long vs_ops(long opens, long reads, long writes) {
      long ok = 0; char c = 'x';
      for (long i = 0; i < opens; i++) { int fd = open(vs_path, O_RDONLY); if (fd >= 0) { ok++; close(fd); } }
      for (long i = 0; i < writes; i++) if (pwrite(vs_fd, &c, 1, 0) == 1) ok++;
      for (long i = 0; i < reads; i++) if (pread(vs_fd, &c, 1, 0) == 1) ok++;
      return ok;
    }
    long vs_cleanup(void) { if (vs_fd >= 0) close(vs_fd); return (long)unlink(vs_path); }
  C
  ffi_func :vs_pid, [], :long
  ffi_func :vs_prepare, [], :long
  ffi_func :vs_ops, [:long, :long, :long], :long
  ffi_func :vs_cleanup, [], :long
end

USAGE = "usage: vfsstat [--duration-ms MS] [--pid TGID] | --selftest"
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
obj.map_put(Cfg, 0, selftest ? VS.vs_pid : pid)
lr = obj.attach_kprobe("on_read")
lw = obj.attach_kprobe("on_write")
lo = obj.attach_kprobe("on_open")
if selftest
  if VS.vs_prepare != 0
    raise "vfsstat: cannot create the temporary file"
  end
  r0 = obj.counter_get(Reads)
  w0 = obj.counter_get(Writes)
  o0 = obj.counter_get(Opens)
  ops = VS.vs_ops(10, 20, 30)
  r1 = obj.counter_get(Reads)
  w1 = obj.counter_get(Writes)
  o1 = obj.counter_get(Opens)
  VS.vs_cleanup
  lr.detach
  lw.detach
  lo.detach
  obj.close
  puts "ops=#{ops} opens=#{o1 - o0} reads=#{r1 - r0} writes=#{w1 - w0}"
  if ops != 60 || o1 - o0 != 10 || r1 - r0 != 20 || w1 - w0 != 30
    puts "selftest FAILED: want ops=60 opens=10 reads=20 writes=30"
    exit 1
  end
  puts "selftest ok"
else
  puts "counting vfs_read / vfs_write / vfs_open for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
  lr.detach
  lw.detach
  lo.detach
  puts "reads=#{obj.counter_get(Reads)} writes=#{obj.counter_get(Writes)} opens=#{obj.counter_get(Opens)}"
  obj.close
end
