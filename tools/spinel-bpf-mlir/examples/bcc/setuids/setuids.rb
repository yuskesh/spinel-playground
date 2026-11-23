require "bpf"

# setuids — setuid(2) と setresuid(2) の uid を 1 つずつ印字 (bcc の setuids、spinel-ebpf 23fa4b0 tools/setuids.rb の移植 — P027 E136)。
# eBPF の側: tracepoint syscalls/sys_enter_setuid (uid) と sys_enter_setresuid (ruid・euid・suid) を、呼んだ tgid と種類 (1 = setuid・2 = setresuid) と一緒に ring に。
# uid は下位 32 bit (uid_t) — (uid_t)-1 は 4294967295。Cfg[0] が 0 でなければその tgid だけ。
# offset と型は syscalls の event の形 (args は 16 + 8k の 8 byte — uid_t は符号なし、load の前に tracefs と照合)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Drops = BPF::ArrayMap.new("Drops", :u64, 1)
Ev = Struct.new(:tgid, :kind, :a, :b, :c)
BPF.record(Ev, tgid: :u32, kind: :u32, a: :u32, b: :u32, c: :u32)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0, 0, 0), 65536)

def on_setuid(ctx)
  tgid = BPF.pid_tgid >> 32
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      unless Events.output(Ev.new(tgid, 1, ctx.field(:uid) & 0xFFFF_FFFF, 0, 0))
        Drops.atomic_add(0, 1)
      end
    end
  end
end
BPF.tracepoint :on_setuid, "syscalls/sys_enter_setuid", fields: {uid: [16, :u64]}

def on_setresuid(ctx)
  tgid = BPF.pid_tgid >> 32
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      unless Events.output(Ev.new(tgid, 2, ctx.field(:ruid) & 0xFFFF_FFFF, ctx.field(:euid) & 0xFFFF_FFFF, ctx.field(:suid) & 0xFFFF_FFFF))
        Drops.atomic_add(0, 1)
      end
    end
  end
end
BPF.tracepoint :on_setresuid, "syscalls/sys_enter_setresuid", fields: {ruid: [16, :u64], euid: [24, :u64], suid: [32, :u64]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   setuids [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の setuid / setresuid を印字
#   setuids --selftest                         自分の tgid に絞り setuid(今の uid) を 10 回と setresuid(-1, -1, -1) を 10 回 (uid は変わらない) —
#                                              setuid の event 10 (今の uid)・setresuid の event 10 (3 つとも 4294967295) を照らす
require "spinelbpf"

# SU は自分の pid と uid と、uid を変えない setuid / setresuid (例の中の inline C)。
module SU
  ffi_source <<~C
    #include <unistd.h>
    long su_pid(void) { return (long)getpid(); }
    long su_uid(void) { return (long)getuid(); }
    long su_ids(void) { uid_t r, e, s; if (getresuid(&r, &e, &s) != 0) return -1; return (long)r * 1000000000000L + (long)e * 1000000L + (long)s; }
    long su_calls(long n) {
      long ok = 0;
      for (long i = 0; i < n; i++) if (setuid(getuid()) == 0) ok++;
      for (long i = 0; i < n; i++) if (setresuid((uid_t)-1, (uid_t)-1, (uid_t)-1) == 0) ok++;
      return ok;
    }
  C
  ffi_func :su_pid, [], :long
  ffi_func :su_uid, [], :long
  ffi_func :su_calls, [:long], :long
  ffi_func :su_ids, [], :long
end

USAGE = "usage: setuids [--duration-ms MS] [--pid TGID] | --selftest"
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

me = SU.su_pid
uid = SU.su_uid
obj = SpinelBPF.load_embedded
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
obj.map_put(Cfg, 0, selftest ? me : pid)
r = obj.ringbuf(Events)
l1 = obj.attach_tracepoint("on_setuid")
l2 = obj.attach_tracepoint("on_setresuid")
calls = 0
if selftest
  calls = SU.su_calls(10)
else
  puts "tracing setuid / setresuid for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l1.detach
l2.detach
puts "    TGID  CALL        UID / RUID EUID SUID"
n1 = 0
n2 = 0
ok1 = 0
ok2 = 0
v = r.read_record(200)
while v.length > 0
  if v[1] == 1
    puts "#{v[0].to_s.rjust(8)}  setuid     #{v[2]}"
    n1 += 1
    ok1 += 1 if v[2] == uid
  else
    puts "#{v[0].to_s.rjust(8)}  setresuid  #{v[2]} #{v[3]} #{v[4]}"
    n2 += 1
    ok2 += 1 if v[2] == 4294967295 && v[3] == 4294967295 && v[4] == 4294967295
  end
  v = r.read_record(200)
end
drops = obj.map_get(Drops, 0)
r.close
obj.close
puts "setuid=#{n1} setresuid=#{n2} drops=#{drops}"
if selftest
  ids = SU.su_ids
  puts "calls=#{calls} setuid_matching=#{ok1} setresuid_matching=#{ok2}"
  puts "after: ruid=#{ids / 1000000000000} euid=#{(ids / 1000000) % 1000000} suid=#{ids % 1000000} (getresuid — the uid does not change)"
  if calls != 20 || n1 != 10 || n2 != 10 || ok1 != 10 || ok2 != 10
    puts "selftest FAILED: want calls=20 setuid=10 setresuid=10 (all matching)"
    exit 1
  end
  puts "selftest ok"
end
