require "bpf"

# filelife — file の作成から削除までの寿命を 1 つずつ印字 (bcc の filelife、spinel-ebpf 23fa4b0 tools/filelife.rb の移植 — P028 E148)。
# eBPF の側: kprobe security_inode_create(struct inode *dir, struct dentry *dentry, umode_t) の dentry (第 2 引数) の pointer (raw の 64 bit —
# E146 の :ptr、参照しない) を key に作成の時刻を Born に、kprobe vfs_unlink(…, struct inode *dir, struct dentry *dentry, …) の dentry (第 3 引数) で
# 同じ key の差を ring に (名前は出さない — spinel-ebpf と同じ)。Cfg[0] が 0 でなければその tgid だけ。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Born = BPF::HashMap.new("Born", :i64, :u64, 10240)
Sent = BPF::ArrayMap.new("Sent", :u64, 2)
Ev = Struct.new(:tgid, :pad, :ns)
BPF.record(Ev, tgid: :u32, pad: :u32, ns: :i64)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0), 65536)

def on_create(ctx)
  tgid = (BPF.pid_tgid >> 32) & 0xFFFF_FFFF
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      _ = Born.update(ctx.arg(2), BPF.ktime_ns)
    end
  end
end
BPF.kprobe :on_create, "security_inode_create", params: {2 => :ptr}

def on_unlink(ctx)
  tgid = (BPF.pid_tgid >> 32) & 0xFFFF_FFFF
  de = ctx.arg(3)
  t = Born.lookup(de)
  if t
    d = (BPF.ktime_ns & 0x7FFF_FFFF_FFFF_FFFF) - (t.load & 0x7FFF_FFFF_FFFF_FFFF)
    _ = Born.delete(de)
    unless Events.output(Ev.new(tgid, 0, d))
      Sent.atomic_add(1, 1)
    end
  end
end
BPF.kprobe :on_unlink, "vfs_unlink", params: {3 => :ptr}

# user 空間の側 — 普通の Ruby (Spinel)。
#   filelife [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) に作られて消された file の寿命を印字
#   filelife --selftest                         自分の tgid に絞り、TMPDIR に file を 3 つ作り 10 ms 後に unlink — event がちょうど 3 つで各寿命 ≥ 10 ms
require "spinelbpf"

# FL は自分の pid と、TMPDIR の file の作成・usleep・unlink (例の中の inline C)。
module FL
  ffi_source <<~C
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>
    long fl_pid(void) { return (long)getpid(); }
    long fl_lives(long n) {
      const char *d = getenv("TMPDIR");
      long ok = 0;
      for (long i = 0; i < n; i++) {
        char p[4096];
        int k = snprintf(p, sizeof p, "%s/filelife-%ld-%ld", (d && *d) ? d : "/tmp", (long)getpid(), i);
        if (k <= 0 || k >= (int)sizeof p) return -1;
        int fd = open(p, O_CREAT | O_EXCL | O_WRONLY, 0600);
        if (fd < 0) return -2;
        close(fd);
        usleep(10000);
        if (unlink(p) == 0) ok++;
      }
      return ok;
    }
  C
  ffi_func :fl_pid, [], :long
  ffi_func :fl_lives, [:long], :long
end

USAGE = "usage: filelife [--duration-ms MS] [--pid TGID] | --selftest"
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
obj.map_put(Cfg, 0, selftest ? FL.fl_pid : pid)
r = obj.ringbuf(Events)
lc = obj.attach_kprobe("on_create")
lu = obj.attach_kprobe("on_unlink")
lives = 0
if selftest
  lives = FL.fl_lives(3)
else
  puts "tracing file lifetimes for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
lc.detach
lu.detach
puts "    TGID   LIFETIME_MS"
mine = 0
long = 0
v = r.read_record(200)
while v.length > 0
  puts "#{v[0].to_s.rjust(8)} #{(v[2] / 1000000.0).round(3).to_s.rjust(13)}"
  if v[0] == FL.fl_pid
    mine += 1
    long += 1 if v[2] >= 10_000_000
  end
  v = r.read_record(200)
end
r.close
obj.close
puts "events=#{mine}"
if selftest
  puts "lives=#{lives} mine=#{mine} at_least_10ms=#{long}"
  if lives != 3 || mine != 3 || long != 3
    puts "selftest FAILED: want lives=3 and exactly 3 events of this process, each ≥ 10 ms"
    exit 1
  end
  puts "selftest ok"
end
