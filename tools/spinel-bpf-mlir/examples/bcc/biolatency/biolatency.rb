require "bpf"

# biolatency — block I/O の request の始まりから終わりまでの時間の log2 の histogram (bcc の biolatency、spinel-ebpf 23fa4b0 tools/biolatency.rb の移植 —
# P028 E148)。eBPF の側: kprobe blk_mq_start_request(struct request *rq) で request の pointer (raw の 64 bit — E146 の :ptr、参照しない) を key に
# 始まりの時刻を Start に、kprobe blk_mq_end_request(struct request *rq, …) で同じ key の差を log2 の bucket で Hist に。始まりの数を Out[0] に。
# **注**: NVMe 等の完了は blk_mq_end_request_batch を通る path があり、そこでは blk_mq_end_request が呼ばれない — その I/O は Hist に入らない
# (bcc の biolatency が tracepoint block_rq_issue / complete に移った理由)。system 全体の I/O (絞りは無い)。
Start = BPF::HashMap.new("Start", :i64, :u64, 10240)
Hist = BPF::ArrayMap.new("Hist", :u64, 64)
Out = BPF::ArrayMap.new("Out", :u64, 1)

# log2_bucket は v (≥ 0) の 2 を底の対数の整数部 (0 は 0) — bcc の bpf_log2l と同じ bucket (runqlat と同じ)。
def log2_bucket(v)
  b = 0
  if v >= 0x1_0000_0000
    b += 32
    v = v >> 32
  end
  if v >= 0x1_0000
    b += 16
    v = v >> 16
  end
  if v >= 0x100
    b += 8
    v = v >> 8
  end
  if v >= 0x10
    b += 4
    v = v >> 4
  end
  if v >= 4
    b += 2
    v = v >> 2
  end
  if v >= 2
    b += 1
  end
  b
end

def on_start(ctx)
  _ = Start.update(ctx.arg(1), BPF.ktime_ns)
  Out.atomic_add(0, 1)
end
BPF.kprobe :on_start, "blk_mq_start_request", params: {1 => :ptr}

def on_end(ctx)
  rq = ctx.arg(1)
  t = Start.lookup(rq)
  if t
    d = (BPF.ktime_ns & 0x7FFF_FFFF_FFFF_FFFF) - (t.load & 0x7FFF_FFFF_FFFF_FFFF)
    _ = Start.delete(rq)
    if d > 0
      Hist.atomic_add(log2_bucket(d) & 63, 1) # helper の戻り値は呼び手で i64 の全域 — bucket は 0〜63 なので & 63 は値を変えない
    end
  end
end
BPF.kprobe :on_end, "blk_mq_end_request", params: {1 => :ptr}

# user 空間の側 — 普通の Ruby (Spinel)。
#   biolatency [--duration-ms MS]   MS の間 (既定 5000) 測り log2 の histogram を印字 (system 全体)
#   biolatency --selftest --dir DIR DIR の file に書いて fsync を 3 回 (smoke) — 始まりの数 > 0 を照らす。Hist の合計は照らさない (注)。
#                                   DIR が無い・tmpfs なら前提を満たさないので名指しで止める (tmpfs の fsync は block I/O を出さない、sudo は TMPDIR を落とす — E148 追補 1・2)
require "spinelbpf"

# BL は --dir の file への write と fsync と、その fs が tmpfs かの検査 (例の中の inline C)。
module BL
  ffi_source <<~C
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/vfs.h>
    #include <unistd.h>
    /* bl_tmpfs は d が tmpfs (0x01021994) か — tmpfs の fsync は block I/O を出さないので selftest の前提を満たさない (E148 追補 1・2 — d は --dir、sudo は TMPDIR を落とす) */
    long bl_tmpfs(const char *d) {
      struct statfs s;
      if (statfs(d, &s) != 0) return -1;
      return s.f_type == 0x01021994 ? 1 : 0;
    }
    long bl_fsyncs(const char *d, long n) {
      char p[4096];
      int k = snprintf(p, sizeof p, "%s/biolatency-%ld", d, (long)getpid());
      if (k <= 0 || k >= (int)sizeof p) return -1;
      int fd = open(p, O_CREAT | O_WRONLY | O_TRUNC, 0600);
      if (fd < 0) return -2;
      char buf[4096];
      memset(buf, 0x5a, sizeof buf);
      long ok = 0;
      for (long i = 0; i < n; i++) {
        if (write(fd, buf, sizeof buf) == (ssize_t)sizeof buf && fsync(fd) == 0) ok++;
      }
      close(fd);
      unlink(p);
      return ok;
    }
  C
  ffi_func :bl_tmpfs, [:str], :long
  ffi_func :bl_fsyncs, [:str, :long], :long
end

# hist_total は Hist の 64 の bucket の合計。
def hist_total(obj)
  s = 0
  b = 0
  while b < 64
    s += obj.map_get(Hist, b)
    b += 1
  end
  s
end

# print_hist は 0 でない bucket の範囲を bcc の形 (low -> high : count) で印字する。
def print_hist(obj, unit)
  lo = -1
  hi = -1
  b = 0
  while b < 64
    if obj.map_get(Hist, b) > 0
      lo = b if lo < 0
      hi = b
    end
    b += 1
  end
  puts "     #{unit}               : count"
  if lo < 0
    puts "     (no events)"
    return
  end
  b = lo
  while b <= hi
    low = b == 0 ? 0 : (1 << b)
    high = (1 << (b + 1)) - 1
    puts "#{low.to_s.rjust(20)} -> #{high.to_s.ljust(20)} : #{obj.map_get(Hist, b)}"
    b += 1
  end
end

USAGE = "usage: biolatency [--duration-ms MS] | --selftest --dir DIR"
selftest = false
duration_ms = 5000
dir = ""
i = 0
while i < ARGV.length
  a = ARGV[i]
  if a == "--selftest"
    selftest = true
    i += 1
  elsif a == "--dir" && i + 1 < ARGV.length
    dir = ARGV[i + 1]
    i += 2
  elsif a == "--duration-ms" && i + 1 < ARGV.length
    duration_ms = ARGV[i + 1].to_i
    i += 2
  else
    raise "#{USAGE} (unknown argument #{a})"
  end
end

if selftest && (dir == "" || BL.bl_tmpfs(dir) != 0)
  puts "selftest FAILED: --dir is missing, a tmpfs or unreadable — a tmpfs fsync issues no block I/O; pass --dir with a directory on a block device"
  exit 1
end
obj = SpinelBPF.load_embedded
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
s = obj.attach_kprobe("on_start")
e = obj.attach_kprobe("on_end")
ok = 0
if selftest
  ok = BL.bl_fsyncs(dir, 3)
else
  puts "tracing block I/O latency for #{duration_ms} ms (completions through blk_mq_end_request_batch are not counted)"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
s.detach
e.detach
starts = obj.map_get(Out, 0)
total = hist_total(obj)
print_hist(obj, "nsecs")
obj.close
puts "starts=#{starts} completed=#{total}"
if selftest
  puts "fsyncs=#{ok}"
  if ok != 3 || starts <= 0
    puts "selftest FAILED: want fsyncs=3 and starts > 0"
    exit 1
  end
  puts "selftest ok"
end
