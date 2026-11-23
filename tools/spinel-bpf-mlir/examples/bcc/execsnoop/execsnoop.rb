require "bpf"

# execsnoop — execve の path と argv を 1 つずつ印字 (bcc の execsnoop、spinel-ebpf 23fa4b0 tools/execsnoop.rb の移植 — P028 E151)。
# eBPF の側: ksyscall execve の filename (第 1 引数 — ctx.str_arg(1)) を kind 0 の event に、argv (第 2 引数 — ctx.argv_arg(2)) の slot 0..19 を
# kind 1 の event に 1 つずつ (R.output_argv — bpf-mlir E548 の str_at の 20 段)。**argv は先頭 20 で打ち切り** — 20 の event は「argv が
# ちょうど 20」と「21 以上」を区別しない (spinel-ebpf の emit_argv は全てを歩くが、bpf-mlir の str_at は固定の 0..19 だけ)。
# Cfg[0] が 0 でなければその tgid (execve する process) だけ。
Ev = Struct.new(:kind, :index, :pid, :pad, :arg, :status)
BPF.record(Ev, kind: :u32, index: :u32, pid: :u32, pad: :u32, arg: [:u8, 64], status: :i64)
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0, 0, Array.new(64, 0), 0), 262144)

def on_exec(ctx)
  tgid = (BPF.pid_tgid >> 32) & 0xFFFF_FFFF
  m = 0
  c = Cfg.lookup(0)
  if c
    m = c.load
  end
  if m == 0 || m == tgid
    _ = Events.output_str(Ev.new(0, 0, tgid, 0, Array.new(64, 0), 0), :arg, ctx.str_arg(1), :status)
    _ = Events.output_argv(Ev.new(1, 0, tgid, 0, Array.new(64, 0), 0), :arg, ctx.argv_arg(2), :status, :index)
  end
end
BPF.ksyscall :on_exec, "execve", params: {1 => :user_str, 2 => :user_str_array}

# user 空間の側 — 普通の Ruby (Spinel)。
#   execsnoop [--duration-ms MS]   MS の間 (既定 5000) の execve の path と argv (先頭 20) を印字 (system 全体)
#   execsnoop --selftest           子を 1 つ fork し (子は pipe で待つ)、Cfg に子の pid を書いてから子が execve("/nonexistent-e151",
#                                  ["e151x", "alpha", "beta"]) — 子の path の event 1 つと argv の event 3 つ (index 0..2) を照らす
require "spinelbpf"

# EX は子の fork と execve (例の中の inline C — 子は pipe の 1 byte を待ち、存在しない path を execve して _exit(127))。path と argv の文字列は
# fork の前に親の stack の配列に写す (anon の page — 子に写る)。C の literal (.rodata) のままだと子の page table にまだ無く、BPF の読みは page を
# fault で入れられず −EFAULT で空になる (E151 追補 2 — 実の execsnoop でも同じ制約)。
module EX
  ffi_source <<~C
    #include <string.h>
    #include <sys/types.h>
    #include <sys/wait.h>
    #include <unistd.h>
    static int ex_fd = -1;
    long ex_spawn(void) {
      char path[32], a0[16], a1[16], a2[16];
      strcpy(path, "/nonexistent-e151");
      strcpy(a0, "e151x");
      strcpy(a1, "alpha");
      strcpy(a2, "beta");
      char *const av[] = {a0, a1, a2, 0};
      char *const ev[] = {0};
      int pp[2];
      if (pipe(pp) != 0) return -1;
      pid_t p = fork();
      if (p == 0) {
        char b;
        close(pp[1]);
        if (read(pp[0], &b, 1) != 1) _exit(126);
        execve(path, av, ev);
        _exit(127);
      }
      close(pp[0]);
      if (p < 0) { close(pp[1]); return -1; }
      ex_fd = pp[1];
      return (long)p;
    }
    long ex_release(long p) {
      char b = 1;
      if (write(ex_fd, &b, 1) != 1) return -1;
      close(ex_fd);
      int st;
      if (waitpid((pid_t)p, &st, 0) < 0) return -1;
      return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    }
  C
  ffi_func :ex_spawn, [], :long
  ffi_func :ex_release, [:long], :long
end

# event_fields は read_record の平らな値 [kind, index, pid, pad, arg[0] … arg[63], status] の [kind, index, pid, arg の文字列 (NUL まで), status]。
def event_fields(v)
  s = ""
  k = 0
  while k < 64 && v[4 + k] != 0
    s += v[4 + k].chr
    k += 1
  end
  [v[0], v[1], v[2], s, v[68]]
end

USAGE = "usage: execsnoop [--duration-ms MS] | --selftest"
selftest = false
duration_ms = 5000
i = 0
while i < ARGV.length
  a = ARGV[i]
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
r = obj.ringbuf(Events)
l = obj.attach_ksyscall("on_exec")
kid = 0
if selftest
  kid = EX.ex_spawn
  obj.map_put(Cfg, 0, kid)
  EX.ex_release(kid)
else
  puts "tracing execve for #{duration_ms} ms (argv: the first 20 only — exactly 20 and 21 or more look the same)"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l.detach
puts "     PID  IDX  ARG"
events = 0
paths = []
args = []
idx = []
sts = []
v = r.read_record(200)
while v.length > 0
  f = event_fields(v)
  events += 1
  if !selftest || f[2] == kid
    if f[0] == 0
      puts "#{f[2].to_s.rjust(8)}    -  #{f[3]}"
      if f[2] == kid
        paths.push(f[3])
        sts.push(f[4])
      end
    else
      puts "#{f[2].to_s.rjust(8)} #{f[1].to_s.rjust(4)}  #{f[3]}"
      if f[2] == kid
        args.push(f[3])
        idx.push(f[1])
        sts.push(f[4])
      end
    end
  end
  v = r.read_record(200)
end
r.close
obj.close
puts "events=#{events}"
if selftest
  # status (read_str の生の値 — NUL を含む長さ) も照らす: 空の文字列 (1) と読めない page の −EFAULT の空を混同しない (E151 追補 2)
  puts "child=#{kid} paths=#{paths.length} args=#{args.join(" ")} index=#{idx.join(",")} status=#{sts.join(",")}"
  if paths != ["/nonexistent-e151"] || args != ["e151x", "alpha", "beta"] || idx != [0, 1, 2] || sts != [18, 6, 6, 5]
    puts "selftest FAILED: want one path /nonexistent-e151 and argv e151x alpha beta at index 0,1,2 with status 18,6,6,5"
    exit 1
  end
  puts "selftest ok"
end
