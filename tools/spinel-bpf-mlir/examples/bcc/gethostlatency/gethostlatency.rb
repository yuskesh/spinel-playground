require "bpf"

# gethostlatency — 名前の解決 (libc の getaddrinfo) の時間を 1 つずつ印字 (bcc の gethostlatency、spinel-ebpf 23fa4b0 tools/gethostlatency.rb の移植 — P029 E156)。
# eBPF の側: uprobe getaddrinfo(const char *name, …) で thread の入口の時刻を Start に置き name を Calls に (output_str)、uretprobe getaddrinfo で
# 同じ thread の時刻の差と戻り値 (int) と comm を Rets に (output_comm)。user の側が tid で入口と戻りを結ぶ。target は system の libc の絶対の path
# (libc は本体に DWARF が無い — build と load の照合は GNU build ID の分けた DWARF /usr/lib/debug/.build-id — bpf-mlir E557、host は libc6-dbg)。
# bcc と違う所: getaddrinfo だけ (gethostbyname・gethostbyname2 は追わない)、host は 64 byte まで (record の配列の上限 — bcc は 80)。
Q = Struct.new(:pid_tgid, :status, :host)
BPF.record(Q, pid_tgid: :u64, status: :i64, host: [:u8, 64])
Calls = BPF::RingBuf.new("Calls", Q.new(0, 0, Array.new(64, 0)), 262144)
R = Struct.new(:pid_tgid, :ns, :ret, :pad, :status, :comm)
BPF.record(R, pid_tgid: :u64, ns: :i64, ret: :i32, pad: :u32, status: :i64, comm: [:u8, 16])
Rets = BPF::RingBuf.new("Rets", R.new(0, 0, 0, 0, 0, Array.new(16, 0)), 262144)
Start = BPF::HashMap.new("Start", :i64, :u64, 10240)
Out = BPF::ArrayMap.new("Out", :i64, 3)

def on_gai(ctx)
  _ = Start.update(BPF.pid_tgid & 0xFFFF_FFFF, BPF.ktime_ns)
  r = Calls.output_str(Q.new(BPF.pid_tgid, 0, Array.new(64, 0)), :host, ctx.str_arg(1), :status)
  if r
    Out.atomic_add(0, 1)
  else
    Out.atomic_add(2, 1)
  end
end
BPF.uprobe :on_gai, "/lib/x86_64-linux-gnu/libc.so.6", "getaddrinfo", params: {1 => :user_str}

def on_gai_ret(ctx)
  t = Start.lookup(BPF.pid_tgid & 0xFFFF_FFFF)
  if t
    d = (BPF.ktime_ns & 0x7FFF_FFFF_FFFF_FFFF) - (t.load & 0x7FFF_FFFF_FFFF_FFFF)
    r = Rets.output_comm(R.new(BPF.pid_tgid, d, ctx.ret, 0, 0, Array.new(16, 0)), :comm, :status)
    if r
      Out.atomic_add(1, 1)
    else
      Out.atomic_add(2, 1)
    end
    _ = Start.delete(BPF.pid_tgid & 0xFFFF_FFFF)
  end
end
BPF.uretprobe :on_gai_ret, "/lib/x86_64-linux-gnu/libc.so.6", "getaddrinfo", ret: :i32

# user 空間の側 — 普通の Ruby (Spinel)。
#   gethostlatency [--libc PATH] [--debug-root DIR] [--pid PID] [--duration-ms MS]   MS の間 (既定 5000) の getaddrinfo を印字 (PID 0 は全ての process — 既定)
#   gethostlatency --selftest [--libc PATH]                        自分の process に attach し、自分で getaddrinfo("127.0.0.1", "80", AI_NUMERICHOST) を
#                                                                  3 回 (網に出ない) — 入口と戻りが 3 組・host は 127.0.0.1・戻り値 0・時間 > 0・pid は自分
# --debug-root DIR は libc の分けた DWARF の build ID の探索の root (既定は bml の /usr/lib/debug — 空文字は探索しない)。
# libc の既定は /lib/x86_64-linux-gnu/libc.so.6 (宣言の path と同じ file — load は file の SHA-256 を schema の binary_sha256 と照らす。
# 生成物の binary_sha256 は build した host の libc — 再現の条件は examples/bcc/README.md)。
require "spinelbpf"

# GH は自分の pid と自分の getaddrinfo (例の中の inline C — 成功の回数)。
module GH
  ffi_source <<~C
    #include <netdb.h>
    #include <string.h>
    #include <sys/socket.h>
    #include <unistd.h>
    long gh_pid(void) { return (long)getpid(); }
    long gh_resolve(long n) {
      long ok = 0;
      for (long i = 0; i < n; i++) {
        struct addrinfo hints, *r = NULL;
        memset(&hints, 0, sizeof hints);
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;
        hints.ai_socktype = SOCK_STREAM;
        if (getaddrinfo("127.0.0.1", "80", &hints, &r) == 0) { freeaddrinfo(r); ok++; }
      }
      return ok;
    }
  C
  ffi_func :gh_pid, [], :long
  ffi_func :gh_resolve, [:long], :long
end

USAGE = "usage: gethostlatency [--libc PATH] [--debug-root DIR] [--pid PID] [--duration-ms MS] | --selftest [--libc PATH]"
libc = "/lib/x86_64-linux-gnu/libc.so.6"
debug_root = ""
debug_root_set = false
pid = 0
duration_ms = 5000
selftest = false
i = 0
while i < ARGV.length
  a = ARGV[i]
  if a == "--selftest"
    selftest = true
    i += 1
  elsif a == "--libc" && i + 1 < ARGV.length
    libc = ARGV[i + 1]
    i += 2
  elsif a == "--debug-root" && i + 1 < ARGV.length
    debug_root = ARGV[i + 1]
    debug_root_set = true
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

# bytes_text は record の平らな値 v の from から n byte の NUL までの文字列。
def bytes_text(v, from, n)
  s = ""
  k = from
  while k < from + n && v[k] != 0
    s += v[k].chr
    k += 1
  end
  s
end

pid = GH.gh_pid if selftest
tg = SpinelBPF::UprobeTargets.new
tg.add("on_gai", libc)
tg.add("on_gai_ret", libc)
tg.debug_root(debug_root) if debug_root_set
obj = SpinelBPF.load_embedded_targets(SpinelBPF::ConfigSet.new, tg)
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
rc = obj.ringbuf(Calls)
rr = obj.ringbuf(Rets)
li = obj.attach_uprobe("on_gai", pid)
lr = obj.attach_uretprobe("on_gai_ret", pid)
resolved = 0
if selftest
  resolved = GH.gh_resolve(3)
else
  puts "tracing getaddrinfo in #{libc} for #{duration_ms} ms (pid #{pid}, 0 = every process)"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
li.detach
lr.detach
# 入口 (tid → host) を先に全て読み、戻りを tid で結ぶ (同じ thread の入口は戻りの前 — 窓の中の順)
hosts = {}
calls = 0
v = rc.read_record(200)
while v.length > 0
  hosts[v[0] & 0xFFFF_FFFF] = v[1] < 0 ? "(read failed)" : bytes_text(v, 2, 64)
  calls += 1
  v = rc.read_record(200)
end
puts "     PID COMM                 LATms HOST                             RET"
rets = 0
mine = 0
ok_rows = 0
v = rr.read_record(200)
while v.length > 0
  tid = v[0] & 0xFFFF_FFFF
  h = hosts.key?(tid) ? hosts[tid] : "(no entry)"
  comm = v[4] < 0 ? "(comm failed)" : bytes_text(v, 5, 16)
  puts "#{(v[0] >> 32).to_s.rjust(8)} #{comm.ljust(16)} #{(v[1] / 1000000.0).round(3).to_s.rjust(10)} #{h.ljust(32)} #{v[2]}"
  rets += 1
  if (v[0] >> 32) == pid
    mine += 1
    ok_rows += 1 if h == "127.0.0.1" && v[2] == 0 && v[1] > 0
  end
  v = rr.read_record(200)
end
failed = obj.map_get(Out, 2)
rc.close
rr.close
obj.close
puts "calls=#{calls} returns=#{rets} reservation_failures=#{failed}"
if selftest
  puts "resolved=#{resolved} own_returns=#{mine} own_rows_ok=#{ok_rows}"
  if resolved != 3 || calls != 3 || rets != 3 || ok_rows != 3 || failed != 0
    puts "selftest FAILED: want 3 resolutions, 3 entries and 3 returns of this process (host 127.0.0.1, return 0, latency > 0) and no reservation failure"
    exit 1
  end
  puts "selftest ok"
end
