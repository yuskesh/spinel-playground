require "bpf"

# mountsnoop — mount(2) と umount(2) を path と一緒に 1 つずつ印字 (bcc の mountsnoop、spinel-ebpf 23fa4b0 tools/mountsnoop.rb の移植 — P027 E136・
# path は P028 E147)。eBPF の側: tracepoint syscalls/sys_enter_mount (flags と dir_name — 取り付け先) と sys_enter_umount (flags と name — 外す先) を、
# tgid と種類 (1 = mount・2 = umount) と一緒に ring に。path (user の文字列 — E142 の :user_str) は先頭 63 byte と NUL に切り詰め。
# Cfg[0] が 0 でなければその tgid だけ。offset と型は syscalls の event の形 (mount の flags は 4 番目の unsigned long — 40・dir_name は 2 番目 — 24、
# umount の name は 1 番目 — 16・flags は 2 番目の int — 24、7.1.8 の tracefs は int の引数も signed:0 なので :u64、load の前に tracefs と照合 — E136)。
Cfg = BPF::ArrayMap.new("Cfg", :u32, 1)
Drops = BPF::ArrayMap.new("Drops", :u64, 1)
Sent = BPF::ArrayMap.new("Sent", :u64, 1)
Ev = Struct.new(:tgid, :kind, :flags, :path, :status)
BPF.record(Ev, tgid: :u32, kind: :u32, flags: :u64, path: [:u8, 64], status: :i64)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0, Array.new(64, 0), 0), 65536)

def on_mount(ctx)
  tgid = BPF.pid_tgid >> 32
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      r = Events.output_str(Ev.new(tgid, 1, ctx.field(:flags), Array.new(64, 0), 0), :path, ctx.str_field(:dir_name), :status)
      if r
        Sent.atomic_add(0, 1)
      else
        Drops.atomic_add(0, 1)
      end
    end
  end
end
BPF.tracepoint :on_mount, "syscalls/sys_enter_mount", fields: {dir_name: [24, :user_str], flags: [40, :u64]}

def on_umount(ctx)
  tgid = BPF.pid_tgid >> 32
  c = Cfg.lookup(0)
  if c
    if c.load == 0 || c.load == tgid
      r = Events.output_str(Ev.new(tgid, 2, ctx.field(:flags) & 0xFFFF_FFFF, Array.new(64, 0), 0), :path, ctx.str_field(:name), :status)
      if r
        Sent.atomic_add(0, 1)
      else
        Drops.atomic_add(0, 1)
      end
    end
  end
end
BPF.tracepoint :on_umount, "syscalls/sys_enter_umount", fields: {name: [16, :user_str], flags: [24, :u64]}

# user 空間の側 — 普通の Ruby (Spinel)。
#   mountsnoop [--duration-ms MS] [--pid TGID]   MS の間 (既定 5000) の mount / umount を印字
#   mountsnoop --selftest                         自分の tgid に絞り、自分の mount namespace (unshare と private の伝播) で TMPDIR の下の dir に
#                                                 tmpfs を MS_NOSUID で 3 回 mount と umount — event の (種類・flags) の列が呼んだ順のとおり:
#                                                 伝播の mount 1 (MS_REC|MS_PRIVATE = 0x44000) の後に (mount 2・umount 0) × 3 (E136)、
#                                                 path の列は伝播の `/` の後に自分の dir (`…/mountsnoop-<pid>`) × 6 で、status は path の長さ + 1 (E147)
require "spinelbpf"

# MN は自分の pid と、自分の mount namespace の中の tmpfs の mount / umount (例の中の inline C)。path は自分の process の stack の配列
# (C の literal の "/" も stack に写す — まだ fault で入っていない .rodata の page は BPF が読めない — E151 追補 1・2)。
module MN
  ffi_source <<~C
    #include <linux/sched.h>
    #include <sys/syscall.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/mount.h>
    #include <sys/stat.h>
    #include <unistd.h>
    long mn_pid(void) { return (long)getpid(); }
    long mn_calls(long n) {
      char root[4];
      strcpy(root, "/");
      if (syscall(SYS_unshare, CLONE_NEWNS) != 0) return -1; /* unshare(2) — _GNU_SOURCE の宣言に依らない */
      if (mount("none", root, 0, MS_REC | MS_PRIVATE, 0) != 0) return -2;
      const char *d = getenv("TMPDIR");
      char dir[4096];
      int k = snprintf(dir, sizeof dir, "%s/mountsnoop-%ld", (d && *d) ? d : "/tmp", (long)getpid());
      if (k <= 0 || k >= (int)sizeof dir) return -3;
      if (mkdir(dir, 0700) != 0) return -4;
      long ok = 0;
      for (long i = 0; i < n; i++) {
        if (mount("tmpfs", dir, "tmpfs", MS_NOSUID, 0) == 0) ok++;
        if (umount2(dir, 0) == 0) ok++;
      }
      rmdir(dir);
      return ok;
    }
  C
  ffi_func :mn_pid, [], :long
  ffi_func :mn_calls, [:long], :long
end

# event_fields は read_record の平らな値 [tgid, kind, flags, path[0] … path[63], status] の [tgid, kind, flags, path の文字列 (NUL まで), status]。
def event_fields(v)
  s = ""
  k = 0
  while k < 64 && v[3 + k] != 0
    s += v[3 + k].chr
    k += 1
  end
  [v[0], v[1], v[2], s, v[67]]
end

USAGE = "usage: mountsnoop [--duration-ms MS] [--pid TGID] | --selftest"
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
obj.map_put(Cfg, 0, selftest ? MN.mn_pid : pid)
r = obj.ringbuf(Events)
l1 = obj.attach_tracepoint("on_mount")
l2 = obj.attach_tracepoint("on_umount")
calls = 0
if selftest
  calls = MN.mn_calls(3)
else
  puts "tracing mount / umount for #{duration_ms} ms#{pid > 0 ? " (tgid #{pid})" : ""}"
  $stdout.flush
  sleep(duration_ms / 1000.0)
end
l1.detach
l2.detach
puts "    TGID  CALL    FLAGS  STATUS  PATH"
nm = 0
nu = 0
seq = []
paths = []
sts = []
v = r.read_record(200)
while v.length > 0
  f = event_fields(v)
  seq.push("#{f[1]}:#{f[2]}")
  paths.push(f[3])
  sts.push(f[4])
  if f[1] == 1
    puts "#{f[0].to_s.rjust(8)}  mount   #{f[2].to_s.rjust(6)} #{f[4].to_s.rjust(6)}  #{f[3]}"
    nm += 1
  else
    puts "#{f[0].to_s.rjust(8)}  umount  #{f[2].to_s.rjust(6)} #{f[4].to_s.rjust(6)}  #{f[3]}"
    nu += 1
  end
  v = r.read_record(200)
end
drops = obj.map_get(Drops, 0)
r.close
obj.close
puts "mount=#{nm} umount=#{nu} drops=#{drops}"
if selftest
  want = "1:278528 1:2 2:0 1:2 2:0 1:2 2:0"
  got = seq.join(" ")
  suffix = "/mountsnoop-#{MN.mn_pid}"
  okp = paths.length == 7 && paths[0] == "/" && sts[0] == 2
  k = 1
  while k < paths.length
    p = paths[k]
    okp = false if p.length < suffix.length || p[p.length - suffix.length, suffix.length] != suffix || sts[k] != p.length + 1
    k += 1
  end
  puts "calls=#{calls} sequence=#{got} paths=#{paths.length} status=#{sts.join(",")}"
  if calls != 6 || got != want || !okp
    puts "selftest FAILED: want calls=6 sequence=#{want} (kind:flags — 1 = mount, 2 = umount, 0x44000 = 278528 is the propagation mount) and paths / then …#{suffix} × 6 with status = length + 1"
    exit 1
  end
  puts "selftest ok"
end
