require "bpf"

# biosnoop — block I/O の request ごとの sector・byte 数・latency を 1 つずつ印字 (bcc の biosnoop、spinel-ebpf 23fa4b0 tools/biosnoop.rb の移植 — P029 E155)。
# eBPF の側: fentry blk_mq_start_request(struct request *rq) で検査済みの rq の address (q.addr — bpf-mlir E554 の ebpf.kptr.addr) を key に時刻と
# start の tgid を、fentry blk_mq_end_request(struct request *rq, …) で同じ key の差と rq の __sector / __data_len (CO-RE の kfield) を ring へ。
# **NVMe 等の batch の完了 (blk_mq_end_request_batch) は blk_mq_end_request を通らず join されない** — その I/O は印字されない (biolatency と同じ — E148)。
# attach が違う: bcc は tracepoint block_rq_issue / complete、spinel-ebpf は kprobe (spinel の kprobe には CO-RE の読みが無い) — この移植は fentry (B2 — 利用者の決定)。
# address は生存中の相関用 (free の後の再利用を区別しない — 完了の後に key を消す)。Cfg[0] が 0 でなければその tgid の start を Out[0] に数える (selftest)。
Rq = Struct.new(:__data_len, :__sector)
BPF.kernel_type(Rq, "request", __data_len: :u32, __sector: :u64)
RqT = BPF::KernelType.new(Rq.new(0, 0))

Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 2)
Start = BPF::HashMap.new("Start", :i64, :u64, 10240)
Who = BPF::HashMap.new("Who", :i64, :u64, 10240)
# sector は __sector の下位 63 bit、hi は最上位の bit (sector を持たない request の __sector は (sector_t)-1 — block/blk-mq.c:379 等 — Spinel の Integer に
# 収まらないので BPF の側で分ける — E155 停止 B・追補 4)。kernel_types の __sector の宣言は u64 のまま (幅と符号は requirements の kfield の照合が守る)
Ev = Struct.new(:tgid, :len, :sector, :hi, :pad, :ns)
BPF.record(Ev, tgid: :u32, len: :u32, sector: :i64, hi: :u32, pad: :u32, ns: :i64)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0, 0, 0, 0), 262144)

def on_start(ctx)
  q = ctx.kptr_or_null(0, RqT)
  if q
    tgid = (BPF.pid_tgid >> 32) & 0xFFFF_FFFF
    _ = Start.update(q.addr, BPF.ktime_ns)
    _ = Who.update(q.addr, tgid)
    c = Cfg.lookup(0)
    if c
      if c.load != 0 && c.load == tgid
        Out.atomic_add(0, 1)
      end
    end
  end
end
BPF.fentry :on_start, "blk_mq_start_request", args: {0 => [:or_null, RqT]}

def on_end(ctx)
  q = ctx.kptr_or_null(0, RqT)
  if q
    t = Start.lookup(q.addr)
    if t
      d = (BPF.ktime_ns & 0x7FFF_FFFF_FFFF_FFFF) - (t.load & 0x7FFF_FFFF_FFFF_FFFF)
      w = Who.lookup(q.addr)
      if w
        unless Events.output(Ev.new(w.load & 0xFFFF_FFFF, q.load.__data_len, q.load.__sector & 0x7FFF_FFFF_FFFF_FFFF, q.load.__sector >> 63, 0, d))
          Out.atomic_add(1, 1)
        end
      end
      _ = Start.delete(q.addr)
      _ = Who.delete(q.addr)
    end
  end
end
BPF.fentry :on_end, "blk_mq_end_request", args: {0 => [:or_null, RqT]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   biosnoop [--duration-ms MS]          MS の間 (既定 5000) の block I/O を 1 つずつ印字 (system 全体 — batch の完了は出ない)
#   biosnoop --selftest --dir DIR        DIR (block device の上 — tmpfs は止める) の自分の file の O_DIRECT の 4 KiB の読み 3 回 — 自分の tgid の start が
#                                         1 つ以上 (Out[0]) を照らす。完了の event (join) の数は照らさない (batch の完了で 0 もありうる — 印字だけ — E155 追補 2)
require "spinelbpf"

# BS は自分の pid と、--dir の自分の file の O_DIRECT の読み (例の中の inline C — 読めた回数、tmpfs は -9、誤りは負)。
module BS
  ffi_source <<~C
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/vfs.h>
    #include <unistd.h>
    #ifndef O_DIRECT
    #define O_DIRECT 040000
    #endif
    long bs_pid(void) { return (long)getpid(); }
    long bs_odirect(const char *d, long n) {
      struct statfs sf;
      if (statfs(d, &sf) != 0 || sf.f_type == 0x01021994) return -9;
      char p[4096];
      snprintf(p, sizeof p, "%s/biosnoop-%ld", d, (long)getpid());
      int fd = open(p, O_CREAT | O_TRUNC | O_WRONLY, 0600);
      if (fd < 0) return -1;
      char b[65536];
      memset(b, 0x5a, sizeof b);
      if (write(fd, b, sizeof b) != (ssize_t)sizeof b || fdatasync(fd) != 0) { close(fd); unlink(p); return -2; }
      close(fd);
      fd = open(p, O_RDONLY | O_DIRECT);
      if (fd < 0) { unlink(p); return -3; }
      void *buf = NULL;
      if (posix_memalign(&buf, 4096, 4096) != 0) { close(fd); unlink(p); return -4; }
      long ok = 0;
      for (long i = 0; i < n; i++) if (pread(fd, buf, 4096, 0) == 4096) ok++;
      free(buf);
      close(fd);
      unlink(p);
      return ok;
    }
  C
  ffi_func :bs_pid, [], :long
  ffi_func :bs_odirect, [:str, :long], :long
end

USAGE = "usage: biosnoop [--duration-ms MS] | --selftest --dir DIR"
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

if selftest && dir == ""
  puts "selftest FAILED: --dir is missing — pass a directory on a block device (a tmpfs read issues no block I/O)"
  exit 1
end
obj = SpinelBPF.load_embedded
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
obj.map_put(Cfg, 0, selftest ? BS.bs_pid : 0)
r = obj.ringbuf(Events)
ls = obj.attach_fentry("on_start")
le = obj.attach_fentry("on_end")
reads = 0
if selftest
  reads = BS.bs_odirect(dir, 3)
  obj.map_put(Cfg, 0, 1) # 窓を閉じる (tgid 1)
else
  puts "tracing block I/O for #{duration_ms} ms (completions through blk_mq_end_request_batch are not joined)"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
ls.detach
le.detach
starts = obj.map_get(Out, 0)
puts "    TGID   BYTES          SECTOR      LAT(us)"
events = 0
mine = 0
nosec = 0
v = r.read_record(200)
while v.length > 0
  sec = v[3] == 1 ? "-" : v[2].to_s # 最上位の bit が立つ __sector は sector を持たない request (印字は -、下位 63 bit は nosec の行に)
  if v[3] == 1
    nosec += 1
    puts "nosec low63=0x#{v[2].to_s(16)}"
  end
  puts "#{v[0].to_s.rjust(8)} #{v[1].to_s.rjust(7)} #{sec.rjust(15)} #{(v[5] / 1000.0).round(1).to_s.rjust(12)}"
  events += 1
  mine += 1 if v[0] == BS.bs_pid
  v = r.read_record(200)
end
r.close
obj.close
puts "events=#{events}"
if selftest
  puts "reads=#{reads} own_starts=#{starts} own_completions_joined=#{mine} nosec_events=#{nosec}"
  if reads != 3 || starts < 1
    puts "selftest FAILED: want 3 O_DIRECT reads and at least one start of this process's request (completions are not checked — batched completions are not joined)"
    exit 1
  end
  puts "selftest ok"
end
