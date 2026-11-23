require "bpf"

# capable — capability の検査 (cap の番号と今の task の comm) を 1 つずつ印字 (bcc の capable、spinel-ebpf 23fa4b0 tools/capable.rb の移植 — P028 E148)。
# eBPF の側: kprobe cap_capable(const struct cred *, struct user_namespace *, int cap, unsigned int opts) の cap (第 3 引数 — :i32) と今の task の
# comm (E145 の R.output_comm — bpf_get_current_comm の status は record に) を ring に。Cfg[0] が 0 でなければその tgid だけ。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Sent = BPF::ArrayMap.new("Sent", :u64, 2)
Ev = Struct.new(:tgid, :cap, :comm, :status)
BPF.record(Ev, tgid: :u32, cap: :i32, comm: [:u8, 16], status: :i64)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, Array.new(16, 0), 0), 262144)

def on_cap(ctx)
  tgid = (BPF.pid_tgid >> 32) & 0xFFFF_FFFF
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      r = Events.output_comm(Ev.new(tgid, ctx.arg(3), Array.new(16, 0), 0), :comm, :status)
      if r
        Sent.atomic_add(0, 1)
      else
        Sent.atomic_add(1, 1)
      end
    end
  end
end
BPF.kprobe :on_cap, "cap_capable", params: {3 => :i32}

# user 空間の側 — 普通の Ruby (Spinel)。
#   capable [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の capability の検査を印字
#   capable --selftest                         自分の tgid に絞り、自分の comm を e148cap にして root の setuid(0) を 1 回 —
#                                              cap 7 (CAP_SETUID) の event が 1 つ以上で comm が e148cap (他の検査の event も出うる)
require "spinelbpf"

# CP は自分の pid・comm を替える・setuid(2) を直に (例の中の inline C)。
module CP
  ffi_source <<~C
    #include <sys/prctl.h>
    #include <sys/syscall.h>
    #include <unistd.h>
    long cp_pid(void) { return (long)getpid(); }
    long cp_setcomm(const char *s) { return prctl(PR_SET_NAME, s, 0, 0, 0); }
    long cp_setuid0(void) { return (long)syscall(SYS_setuid, 0); }
  C
  ffi_func :cp_pid, [], :long
  ffi_func :cp_setcomm, [:str], :long
  ffi_func :cp_setuid0, [], :long
end

# event_fields は read_record の平らな値 [tgid, cap, comm[0] … comm[15], status] の [tgid, cap, comm の文字列 (NUL まで), status]。
def event_fields(v)
  s = ""
  k = 0
  while k < 16 && v[2 + k] != 0
    s += v[2 + k].chr
    k += 1
  end
  [v[0], v[1], s, v[18]]
end

USAGE = "usage: capable [--duration-ms MS] [--pid TGID] | --selftest"
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
obj.map_put(Cfg, 0, selftest ? CP.cp_pid : pid)
r = obj.ringbuf(Events)
l = obj.attach_kprobe("on_cap")
su = 0
if selftest
  CP.cp_setcomm("e148cap")
  su = CP.cp_setuid0
  obj.map_put(Cfg, 0, 1) # 窓を閉じる (tgid 1)
else
  puts "tracing capability checks for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l.detach
puts "    TGID  CAP  COMM"
setuid = 0
events = 0
v = r.read_record(200)
while v.length > 0
  f = event_fields(v)
  puts "#{f[0].to_s.rjust(8)} #{f[1].to_s.rjust(4)}  #{f[2]}"
  events += 1
  setuid += 1 if f[1] == 7 && f[2] == "e148cap" && f[3] == 0
  v = r.read_record(200)
end
r.close
obj.close
puts "events=#{events}"
if selftest
  puts "setuid=#{su} cap7_e148cap=#{setuid}"
  if su != 0 || setuid < 1
    puts "selftest FAILED: want setuid(0) to succeed and at least one cap 7 event with comm e148cap (status 0)"
    exit 1
  end
  puts "selftest ok"
end
