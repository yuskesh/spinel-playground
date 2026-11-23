require "bpf"

# deadlock — pthread の mutex の取る順の逆転 (AB-BA — potential deadlock) を印字 (bcc の deadlock、spinel-ebpf 23fa4b0 tools/deadlock.rb の移植 — P029 E157)。
# eBPF の側: uprobe pthread_mutex_lock(pthread_mutex_t *mutex) の mutex (:ptr — raw の i64、bpf-mlir E559) を thread ごとの Held に置き、前に持った
# mutex が在れば辺 (from → to) を Edges に。uprobe pthread_mutex_unlock は引数を読まずに Held を 0 に (元の tool と同じ 1 段の近似 — 偽の辺は出ないが、
# 2 つ以上を持つ間の unlock の後の辺を落とす)。target は system の libc の絶対の path (照合は libc6-dbg の分けた DWARF — bpf-mlir E557)。
# bcc と違う所: 1 段 (bcc は thread ごとの持っている mutex の全て)、stack は出さない、--pid は必須 (全ての process の libc には attach しない)。
E = Struct.new(:pid_tgid, :from, :to)
BPF.record(E, pid_tgid: :u64, from: :i64, to: :i64)
Edges = BPF::RingBuf.new("Edges", E.new(0, 0, 0), 262144)
Held = BPF::HashMap.new("Held", :i64, :i64, 10240)
Out = BPF::ArrayMap.new("Out", :i64, 3)

def on_lock(ctx)
  tid = BPF.pid_tgid & 0xFFFF_FFFF
  m = ctx.arg(1)
  prev = Held.lookup(tid)
  if prev
    p = prev.load
    if p != 0
      if Edges.output(E.new(BPF.pid_tgid, p, m))
        Out.atomic_add(1, 1)
      else
        Out.atomic_add(2, 1)
      end
    end
  end
  _ = Held.update(tid, m)
  Out.atomic_add(0, 1)
end
BPF.uprobe :on_lock, "/lib/x86_64-linux-gnu/libc.so.6", "pthread_mutex_lock", params: {1 => :ptr}

def on_unlock(ctx)
  _ = Held.update(BPF.pid_tgid & 0xFFFF_FFFF, 0)
end
BPF.uprobe :on_unlock, "/lib/x86_64-linux-gnu/libc.so.6", "pthread_mutex_unlock", params: {}

# user 空間の側 — 普通の Ruby (Spinel)。
#   deadlock --pid PID [--libc PATH] [--duration-ms MS]   MS の間 (既定 5000) PID の mutex の辺を集め、逆転の組を印字
#   deadlock --selftest [--libc PATH]                      自分の process に attach し、自分の 2 つの mutex を A・B・(離す)・B・A の順に取る
#                                                          — 自分の 2 つの address の逆転の組がちょうど 1 つ
# libc の既定は /lib/x86_64-linux-gnu/libc.so.6 (宣言の path と同じ file — 生成物の binary_sha256 は build した host の libc — 再現の条件は
# examples/bcc/README.md)。
require "spinelbpf"

# DL は自分の pid と自分の 2 つの mutex (例の中の inline C)。
module DL
  ffi_source <<~C
    #include <pthread.h>
    #include <unistd.h>
    static pthread_mutex_t dl_m[2] = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_MUTEX_INITIALIZER};
    long dl_pid(void) { return (long)getpid(); }
    long dl_addr(long i) { return (long)&dl_m[i]; }
    long dl_abba(void) {
      pthread_mutex_lock(&dl_m[0]); pthread_mutex_lock(&dl_m[1]);
      pthread_mutex_unlock(&dl_m[1]); pthread_mutex_unlock(&dl_m[0]);
      pthread_mutex_lock(&dl_m[1]); pthread_mutex_lock(&dl_m[0]);
      pthread_mutex_unlock(&dl_m[0]); pthread_mutex_unlock(&dl_m[1]);
      return 0;
    }
  C
  ffi_func :dl_pid, [], :long
  ffi_func :dl_addr, [:long], :long
  ffi_func :dl_abba, [], :long
end

USAGE = "usage: deadlock --pid PID [--libc PATH] [--duration-ms MS] | --selftest [--libc PATH]"
libc = "/lib/x86_64-linux-gnu/libc.so.6"
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
pid = DL.dl_pid if selftest
if pid <= 0
  raise "#{USAGE} (--pid is required — deadlock does not attach to every process's libc)"
end

tg = SpinelBPF::UprobeTargets.new
tg.add("on_lock", libc)
tg.add("on_unlock", libc)
obj = SpinelBPF.load_embedded_targets(SpinelBPF::ConfigSet.new, tg)
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
rd = obj.ringbuf(Edges)
ll = obj.attach_uprobe("on_lock", pid)
lu = obj.attach_uprobe("on_unlock", pid)
if selftest
  DL.dl_abba
else
  puts "tracing pthread_mutex_lock order of pid #{pid} for #{duration_ms} ms"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
ll.detach
lu.detach
froms = []
tos = []
v = rd.read_record(200)
while v.length > 0
  froms.push(v[1])
  tos.push(v[2])
  v = rd.read_record(200)
end
failed = obj.map_get(Out, 2)
rd.close
obj.close
puts "edges=#{froms.length} reservation_failures=#{failed}"
# 逆転の組: 辺 f→t と t→f の両方 (組は f < t の 1 つとして数える)
pairs = 0
own = 0
a0 = DL.dl_addr(0)
a1 = DL.dl_addr(1)
j = 0
while j < froms.length
  f = froms[j]
  t = tos[j]
  if f < t
    k = 0
    found = false
    while k < froms.length
      if froms[k] == t && tos[k] == f
        found = true
      end
      k += 1
    end
    if found
      puts "potential deadlock: mutex #{f} and mutex #{t} are taken in both orders"
      pairs += 1
      own += 1 if (f == a0 && t == a1) || (f == a1 && t == a0)
    end
  end
  j += 1
end
puts "inversions=#{pairs}"
if selftest
  puts "own_mutexes=#{a0},#{a1} own_inversions=#{own}"
  if own != 1 || failed != 0
    puts "selftest FAILED: want exactly one inversion of this process's two mutexes and no reservation failure"
    exit 1
  end
  puts "selftest ok"
end
