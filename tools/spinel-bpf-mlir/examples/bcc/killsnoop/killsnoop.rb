require "bpf"

# killsnoop — kill(2) の送り手と相手と signal を 1 つずつ印字 (bcc の killsnoop、spinel-ebpf 23fa4b0 tools/killsnoop.rb の移植 — P027 E136)。
# eBPF の側: tracepoint syscalls/sys_enter_kill の pid (相手) と sig を、送り手の tgid と一緒に ring に。Cfg[0] が 0 でなければその tgid の送りだけ。
# offset と型は syscalls の event の形 (args は 16 + 8k の 8 byte — 7.1.8 の tracefs は pid_t / int の引数も signed:0 なので :u64、load の前に tracefs と照合 — E136)。
# 相手の pid と sig は下位 32 bit を u32 で ring に (user の側で 32 bit の 2 の補数として符号付きに — kill(-pgid) は負)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Drops = BPF::ArrayMap.new("Drops", :u64, 1)
Ev = Struct.new(:tgid, :pid, :sig)
BPF.record(Ev, tgid: :u32, pid: :u32, sig: :u32)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0), 65536)

def on_kill(ctx)
  tgid = BPF.pid_tgid >> 32
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      unless Events.output(Ev.new(tgid, ctx.field(:pid) & 0xFFFF_FFFF, ctx.field(:sig) & 0xFFFF_FFFF))
        Drops.atomic_add(0, 1)
      end
    end
  end
end
BPF.tracepoint :on_kill, "syscalls/sys_enter_kill", fields: {pid: [16, :u64], sig: [24, :u64]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   killsnoop [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の kill(2) を印字
#   killsnoop --selftest                         自分の tgid に絞り kill(自分, 0) を 20 回 — event はちょうど 20 で相手 = 自分・sig = 0 を照らす
require "spinelbpf"

# KS は自分の pid と kill(自分, 0) (例の中の inline C)。
module KS
  ffi_source <<~C
    #include <signal.h>
    #include <unistd.h>
    long ks_pid(void) { return (long)getpid(); }
    long ks_kills(long n) { long ok = 0; for (long i = 0; i < n; i++) if (kill(getpid(), 0) == 0) ok++; return ok; }
  C
  ffi_func :ks_pid, [], :long
  ffi_func :ks_kills, [:long], :long
end

# s32 は 32 bit の 2 の補数の値 (u32 で受けた pid / sig) の符号付きの値。
def s32(v)
  v >= 0x8000_0000 ? v - 0x1_0000_0000 : v
end

USAGE = "usage: killsnoop [--duration-ms MS] [--pid TGID] | --selftest"
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

me = KS.ks_pid
obj = SpinelBPF.load_embedded
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
obj.map_put(Cfg, 0, selftest ? me : pid)
r = obj.ringbuf(Events)
l = obj.attach_tracepoint("on_kill")
kills = 0
if selftest
  kills = KS.ks_kills(20)
else
  puts "tracing kill(2) for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l.detach
puts "    TGID   TARGET  SIG"
events = 0
good = 0
v = r.read_record(200)
while v.length > 0
  target = s32(v[1])
  sig = s32(v[2])
  puts "#{v[0].to_s.rjust(8)} #{target.to_s.rjust(8)} #{sig.to_s.rjust(4)}"
  events += 1
  good += 1 if v[0] == me && target == me && sig == 0
  v = r.read_record(200)
end
drops = obj.map_get(Drops, 0)
r.close
obj.close
puts "events=#{events} drops=#{drops}"
if selftest
  puts "kills=#{kills} matching=#{good}"
  if kills != 20 || events != 20 || good != 20
    puts "selftest FAILED: want kills=20 events=20 matching=20"
    exit 1
  end
  puts "selftest ok"
end
