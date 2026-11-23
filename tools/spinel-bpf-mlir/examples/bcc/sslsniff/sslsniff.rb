require "bpf"

# sslsniff — TLS の暗号化の前の平文を印字 (bcc の sslsniff、spinel-ebpf 23fa4b0 tools/sslsniff.rb の移植 — P029 E158)。
# eBPF の側: uprobe libssl の SSL_write(SSL *s, const void *buf, int num) の buf の先頭 64 byte (:user_buf — bpf-mlir E560 の user.read —
# n = max(0, min(num, 64))、data 全体をゼロ化してから n byte、status は probe_read_user の生の値、count は n) と num を Writes に。
# target は system の libssl の絶対の path (libssl は本体に DWARF が無い — 照合は libssl3t64-dbgsym の分けた DWARF — bpf-mlir E557)。
# bcc と違う所: SSL_write だけ (SSL_read は戻りの時に入口の buffer を読む口が無い)、平文は 64 byte まで (bcc は 8192)、comm は出さない、
# --pid は必須 (全ての process の libssl には attach しない)。
W = Struct.new(:pid_tgid, :status, :count, :len, :data)
BPF.record(W, pid_tgid: :u64, status: :i64, count: :i32, len: :i32, data: [:u8, 64])
Writes = BPF::RingBuf.new("Writes", W.new(0, 0, 0, 0, Array.new(64, 0)), 262144)
Out = BPF::ArrayMap.new("Out", :i64, 2)

def on_write(ctx)
  r = Writes.output_buf(W.new(BPF.pid_tgid, 0, 0, ctx.arg(3), Array.new(64, 0)), :data, ctx.buf_arg(2), ctx.arg(3), :status, :count)
  if r
    Out.atomic_add(0, 1)
  else
    Out.atomic_add(1, 1)
  end
end
BPF.uprobe :on_write, "/usr/lib/x86_64-linux-gnu/libssl.so.3", "SSL_write", params: {2 => :user_buf, 3 => :i32}

# user 空間の側 — 普通の Ruby (Spinel)。
#   sslsniff --pid PID [--libssl PATH] [--duration-ms MS]   MS の間 (既定 5000) PID の SSL_write の平文 (先頭 64 byte) を印字
#   sslsniff --selftest [--libssl PATH]                     自分の process に attach し、例の中の inline C で TLS の client の
#                                                           SSL_write("spinel-sslsniff-selftest", 24) を 1 回 (libssl は dlopen — BIO 無しで -1 を返すが入口の
#                                                           probe は buffer を見る — 網に出ない) — 自分の event がちょうど 1 つで平文・len 24・count 24
# libssl の既定は /usr/lib/x86_64-linux-gnu/libssl.so.3 (宣言の path と同じ file — 生成物の binary_sha256 は build した host の libssl —
# 再現の条件は examples/bcc/README.md)。
require "spinelbpf"

# SS は自分の pid と自分の SSL_write (例の中の inline C)。libssl は link せず、selftest の時だけ dlopen する (実行 file の NEEDED を
# packaging/needed.allow の外に増やさない — E004)。path は --libssl の file (attach した file と同じ)。
module SS
  ffi_source <<~C
    #include <dlfcn.h>
    #include <unistd.h>
    long ss_pid(void) { return (long)getpid(); }
    long ss_write(const char *libssl) {
      void *h = dlopen(libssl, RTLD_NOW | RTLD_LOCAL);
      if (h == NULL) return -1000;
      void *(*method)(void) = (void *(*)(void))dlsym(h, "TLS_client_method");
      void *(*ctx_new)(void *) = (void *(*)(void *))dlsym(h, "SSL_CTX_new");
      void *(*ssl_new)(void *) = (void *(*)(void *))dlsym(h, "SSL_new");
      void (*set_connect)(void *) = (void (*)(void *))dlsym(h, "SSL_set_connect_state");
      int (*write)(void *, const void *, int) = (int (*)(void *, const void *, int))dlsym(h, "SSL_write");
      void (*ssl_free)(void *) = (void (*)(void *))dlsym(h, "SSL_free");
      void (*ctx_free)(void *) = (void (*)(void *))dlsym(h, "SSL_CTX_free");
      if (!method || !ctx_new || !ssl_new || !set_connect || !write || !ssl_free || !ctx_free) return -1001;
      void *ctx = ctx_new(method());
      if (ctx == NULL) return -1002;
      void *s = ssl_new(ctx);
      if (s == NULL) { ctx_free(ctx); return -1003; }
      set_connect(s);
      /* BIO を置かない: SSL_write は handshake を始めて BIO が無いので失敗する (-1) が、入口の uprobe は buf と num を見る — 網に出ない */
      long rc = (long)write(s, "spinel-sslsniff-selftest", 24);
      ssl_free(s);
      ctx_free(ctx);
      return rc;
    }
  C
  ffi_func :ss_pid, [], :long
  ffi_func :ss_write, [:str], :long
end

USAGE = "usage: sslsniff --pid PID [--libssl PATH] [--duration-ms MS] | --selftest [--libssl PATH]"
libssl = "/usr/lib/x86_64-linux-gnu/libssl.so.3"
pid = 0
duration_ms = 5000
selftest = false
i = 0
while i < ARGV.length
  a = ARGV[i]
  if a == "--selftest"
    selftest = true
    i += 1
  elsif a == "--libssl" && i + 1 < ARGV.length
    libssl = ARGV[i + 1]
    i += 2
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
pid = SS.ss_pid if selftest
if pid <= 0
  raise "#{USAGE} (--pid is required — sslsniff does not attach to every process's libssl)"
end

# text は record の平らな値 v の from から n byte (印字できない byte は `.`)。
def text(v, from, n)
  s = ""
  k = 0
  while k < n
    c = v[from + k]
    if c >= 32 && c < 127
      s += c.chr
    else
      s += "."
    end
    k += 1
  end
  s
end

tg = SpinelBPF::UprobeTargets.new
tg.add("on_write", libssl)
obj = SpinelBPF.load_embedded_targets(SpinelBPF::ConfigSet.new, tg)
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
rd = obj.ringbuf(Writes)
lk = obj.attach_uprobe("on_write", pid)
wrote = 0
if selftest
  wrote = SS.ss_write(libssl)
else
  puts "tracing SSL_write of pid #{pid} for #{duration_ms} ms"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
lk.detach
events = 0
mine = 0
ok_rows = 0
v = rd.read_record(200)
while v.length > 0
  # v: pid_tgid, status, count, len, data[64]
  n = v[2]
  puts "WRITE pid=#{v[0] >> 32} len=#{v[3]} status=#{v[1]} shown=#{n}"
  puts "  #{text(v, 4, n)}"
  events += 1
  if (v[0] >> 32) == pid
    mine += 1
    ok_rows += 1 if v[1] == 0 && n == 24 && v[3] == 24 && text(v, 4, 24) == "spinel-sslsniff-selftest"
  end
  v = rd.read_record(200)
end
failed = obj.map_get(Out, 1)
rd.close
obj.close
puts "events=#{events} reservation_failures=#{failed}"
if selftest
  puts "ssl_write_rc=#{wrote} own_events=#{mine} own_rows_ok=#{ok_rows}"
  if mine != 1 || ok_rows != 1 || failed != 0
    puts "selftest FAILED: want exactly one SSL_write event of this process with the 24-byte plaintext and no reservation failure"
    exit 1
  end
  puts "selftest ok"
end
