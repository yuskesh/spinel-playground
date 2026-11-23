require "bpf"

# exitsnoop — process の終わり (pid・tgid・comm) を 1 つずつ印字 (bcc の exitsnoop、spinel-ebpf 23fa4b0 tools/exitsnoop.rb の移植 — P027 E136)。
# eBPF の側: tp_btf sched_process_exit の task (終わる task — 今の task) の pid・tgid を CO-RE で読み、comm の 16 byte を ring の event に写す
# (spinel-ebpf の emit_comm (今の task の comm) と同じ意味 — E119 の kfield.copy の写し先に予約)。幅・符号・名前は load の前の照合が kernel の BTF と照らす。
Task = Struct.new(:pid, :tgid, :comm)
BPF.kernel_type(Task, "task_struct", pid: :i32, tgid: :i32, comm: [:u8, 16])
TaskT = BPF::KernelType.new(Task.new(0, 0, Array.new(16, 0)))
Ev = Struct.new(:comm, :pid, :tgid)
BPF.record(Ev, comm: [:u8, 16], pid: :u32, tgid: :u32)
Drops = BPF::ArrayMap.new("Drops", :u64, 1)
Events = BPF::RingBuf.new("Events", Ev.new(Array.new(16, 0), 0, 0), 262144)

def on_exit(ctx)
  t = ctx.kptr(0, TaskT)
  unless Events.output(Ev.new(t.copy(:comm), t.load.pid & 0xFFFF_FFFF, t.load.tgid & 0xFFFF_FFFF))
    Drops.atomic_add(0, 1)
  end
end
BPF.tp_btf :on_exit, "sched_process_exit", args: {0 => TaskT}

# user 空間の側 — 普通の Ruby (Spinel)。
#   exitsnoop [--duration-ms MS]   MS の間 (既定 5000) の process の終わりを印字 (system 全体)
#   exitsnoop --decode-check       root なし: Events の layout の byte の列を library の read_member で平らに読み、event の読み (event_fields) を照らす (E136)
#   exitsnoop --selftest           子を 5 つ fork (子は名前を e136child にして _exit(0)) — 子の pid の event がちょうど 5 で comm が e136child を照らす
#                                  (他の process の終わりの event は数えない — 絞りは user の側で子の pid の集合)
require "spinelbpf"

# EX は名前を変えて直ちに終わる子の fork (例の中の inline C — 親は wait して子の pid を返す)。
module EX
  ffi_source <<~C
    #include <sys/prctl.h>
    #include <sys/types.h>
    #include <sys/wait.h>
    #include <unistd.h>
    long ex_fork(void) {
      pid_t p = fork();
      if (p == 0) { prctl(PR_SET_NAME, "e136child", 0, 0, 0); _exit(0); }
      if (p < 0) return -1;
      int st; waitpid(p, &st, 0);
      return (long)p;
    }
  C
  ffi_func :ex_fork, [], :long
end

# event_fields は read_record の平らな値 [comm[0] … comm[15], pid, tgid] (配列の member は平らに並ぶ — E136) の [pid, tgid, comm の文字列 (NUL まで)]。
def event_fields(v)
  s = ""
  k = 0
  while k < 16 && v[k] != 0
    s += v[k].chr
    k += 1
  end
  [v[16], v[17], s]
end

# decode_check は root なしで、Events の layout の byte の列 (comm "e136child"・pid 4660・tgid 22136) を library の ring の読みと同じ形
# (record_layout と read_member — 平らな値) で読み、event_fields の結果を照らす。
def decode_check
  lay = SpinelBPF.record_layout(Events)
  buf = Array.new(lay[0], 0)
  name = "e136child"
  k = 0
  while k < name.length
    buf[k] = name[k].ord
    k += 1
  end
  buf[16] = 0x34
  buf[17] = 0x12
  buf[20] = 0x78
  buf[21] = 0x56
  members = lay[1]
  vals = []
  i = 0
  while i < members.length
    vals.push(SpinelBPF.read_member(buf, members[i], "Events", "0"))
    i += 1
  end
  f = event_fields(vals)
  puts "decode: size=#{lay[0]} values=#{vals.length} pid=#{f[0]} tgid=#{f[1]} comm=#{f[2]}"
  f[0] == 4660 && f[1] == 22136 && f[2] == "e136child" && vals.length == 18
end

USAGE = "usage: exitsnoop [--duration-ms MS] | --selftest | --decode-check"
selftest = false
duration_ms = 5000
i = 0
while i < ARGV.length
  a = ARGV[i]
  if a == "--decode-check"
    if decode_check
      puts "decode ok"
      exit 0
    end
    puts "decode FAILED"
    exit 1
  end
  if a == "--selftest"
    selftest = true
    i += 1
  elsif a == "--duration-ms" && i + 1 < ARGV.length
    duration_ms = ARGV[i + 1].to_i
    i += 2
  else
    raise "#{USAGE} (unknown argument #{a})"
  end
end

obj = SpinelBPF.load_embedded
puts "unmet (not blocking): #{obj.unmet.length} (requirements policy #{SpinelBPF.policy_version})"
um = obj.unmet
k = 0
while k < um.length
  puts "  unmet: #{um[k]}"
  k += 1
end
r = obj.ringbuf(Events)
l = obj.attach_tp_btf("on_exit")
kids = []
if selftest
  k = 0
  while k < 5
    kids.push(EX.ex_fork)
    k += 1
  end
else
  puts "tracing process exits for #{duration_ms} ms"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l.detach
puts "     PID     TGID  COMM"
events = 0
mine = 0
named = 0
v = r.read_record(200)
while v.length > 0
  f = event_fields(v)
  events += 1
  if kids.include?(f[0])
    mine += 1
    named += 1 if f[2] == "e136child"
    puts "#{f[0].to_s.rjust(8)} #{f[1].to_s.rjust(8)}  #{f[2]}"
  elsif !selftest
    puts "#{f[0].to_s.rjust(8)} #{f[1].to_s.rjust(8)}  #{f[2]}"
  end
  v = r.read_record(200)
end
drops = obj.map_get(Drops, 0)
r.close
obj.close
puts "events=#{events} drops=#{drops}"
if selftest
  puts "children=#{kids.length} matching=#{mine} named=#{named}"
  if kids.length != 5 || mine != 5 || named != 5
    puts "selftest FAILED: want children=5 matching=5 named=5"
    exit 1
  end
  puts "selftest ok"
end
