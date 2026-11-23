require "bpf"

# E127 H6: 実の attach — 試験が作り消す子の cgroup (/sys/fs/cgroup/spinelbpf-e127) に自分を移し、移した後に作った 127.0.0.1 の UDP の対で payload 1〜200 を
# 1 つずつ送る。ingress (len > 64 — payload > 36 — で deny) を attach → 送受 → detach、egress を attach → 送受 → detach の順 (追補 1 — 別々に)。root
Out = BPF::ArrayMap.new("Out", :u32, 2)

def small_in(skb)
  n = skb.len
  Out.update(0, n)
  pr = 0
  w = skb.check(0, 20)
  if w
    pr = w.u8(9)
  end
  Out.update(1, pr)
  return BPF::CG_DENY if n > 64
  BPF::CG_ALLOW
end

def small_out(skb)
  n = skb.len
  Out.update(0, n)
  pr = 0
  w = skb.check(0, 20)
  if w
    pr = w.u8(9)
  end
  Out.update(1, pr)
  return BPF::CG_DENY if n > 64
  BPF::CG_ALLOW
end
BPF.cgroup_skb :small_in, :ingress
BPF.cgroup_skb :small_out, :egress

require "spinelbpf"

module HCg
  ffi_source <<~C
    #include <stdio.h>
    #include <string.h>
    #include <errno.h>
    #include <fcntl.h>
    #include <poll.h>
    #include <unistd.h>
    #include <sys/stat.h>
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #define HCG_DIR "/sys/fs/cgroup/spinelbpf-e127"
    static char h_orig[600];
    static int h_rs = -1, h_ss = -1;
    static struct sockaddr_in h_dst;
    static char h_buf[4096];
    static long h_procs(const char *dir) {
      char p[700], s[32];
      snprintf(p, sizeof p, "%s/cgroup.procs", dir);
      int fd = open(p, O_WRONLY);
      if (fd < 0) return -1;
      int n = snprintf(s, sizeof s, "%d", (int)getpid());
      long r = write(fd, s, (size_t)n) == n ? 0 : -1;
      close(fd);
      return r;
    }
    long h_exists(void) { struct stat st; return stat(HCG_DIR, &st) == 0 ? 1 : 0; }
    /* 元の cgroup を覚え、子の cgroup を作って自分を移し、その dir の fd を返す (負は失敗 — 既に在る dir は -2) */
    long h_enter(void) {
      FILE *f = fopen("/proc/self/cgroup", "r");
      char line[600];
      if (!f) return -1;
      h_orig[0] = 0;
      while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "0::", 3) == 0) {
          line[strcspn(line, "\\n")] = 0;
          snprintf(h_orig, sizeof h_orig, "/sys/fs/cgroup%s", line + 3);
        }
      }
      fclose(f);
      if (!h_orig[0]) return -1;
      if (mkdir(HCG_DIR, 0755) != 0) return -2;
      if (h_procs(HCG_DIR) != 0) return -3;
      return open(HCG_DIR, O_RDONLY | O_DIRECTORY);
    }
    /* 自分を元の cgroup に戻して子の cgroup を消す (0 は成功) */
    long h_leave(void) {
      if (h_procs(h_orig) != 0) return -1;
      return rmdir(HCG_DIR) == 0 ? 0 : -2;
    }
    /* 127.0.0.1 の UDP の受け手 (bind・non-blocking) と送り手 — 子の cgroup に移った後に作る */
    long h_sockets(void) {
      socklen_t l = sizeof h_dst;
      h_rs = socket(AF_INET, SOCK_DGRAM, 0);
      h_ss = socket(AF_INET, SOCK_DGRAM, 0);
      if (h_rs < 0 || h_ss < 0) return -1;
      memset(&h_dst, 0, sizeof h_dst);
      h_dst.sin_family = AF_INET;
      h_dst.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      if (bind(h_rs, (struct sockaddr *)&h_dst, sizeof h_dst) != 0) return -1;
      if (getsockname(h_rs, (struct sockaddr *)&h_dst, &l) != 0) return -1;
      return 0;
    }
    long h_close(void) { close(h_rs); close(h_ss); h_rs = h_ss = -1; return 0; }
    /* payload n byte を送る — 送った byte 数か -errno */
    long h_send(long n) {
      if (n < 0 || n > (long)sizeof h_buf) return -EINVAL;
      memset(h_buf, 120, (size_t)n);
      long r = (long)sendto(h_ss, h_buf, (size_t)n, 0, (struct sockaddr *)&h_dst, sizeof h_dst);
      return r < 0 ? -errno : r;
    }
    /* 受けた datagram の長さ、20 ms の内に無ければ -1 */
    long h_recv(void) {
      struct pollfd p = {h_rs, POLLIN, 0};
      if (poll(&p, 1, 20) != 1) return -1;
      return (long)recv(h_rs, h_buf, sizeof h_buf, MSG_DONTWAIT);
    }
  C
  ffi_func :h_exists, [], :long
  ffi_func :h_enter, [], :long
  ffi_func :h_leave, [], :long
  ffi_func :h_sockets, [], :long
  ffi_func :h_close, [], :long
  ffi_func :h_send, [:long], :long
  ffi_func :h_recv, [], :long
end

def lens(a)
  s = ""
  i = 0
  while i < a.length
    if i > 0
      s = s + ","
    end
    s = s + a[i].to_s
    i += 1
  end
  s
end

if HCg.h_exists == 1
  raise "/sys/fs/cgroup/spinelbpf-e127 already exists — remove it before the run (E127)"
end
obj = SpinelBPF.load_embedded
cg = HCg.h_enter
if cg < 0
  raise "entering the child cgroup failed (#{cg})"
end
# ingress
l = obj.attach_cgroup("small_in", cg)
if HCg.h_sockets != 0
  raise "sockets failed"
end
sent = 0
got = []
n = 1
while n <= 200
  if HCg.h_send(n) == n
    sent += 1
  end
  r = HCg.h_recv
  if r >= 0
    got.push(r)
  end
  n += 1
end
HCg.h_close
l.detach
puts "in sent=#{sent} got=#{got.length}"
puts "in lens=#{lens(got)}"
# egress
l = obj.attach_cgroup("small_out", cg)
if HCg.h_sockets != 0
  raise "sockets failed"
end
ok = 0
eperm = 0
other = 0
got = []
n = 1
while n <= 200
  r = HCg.h_send(n)
  if r == n
    ok += 1
  elsif r == -1
    eperm += 1
  else
    other += 1
  end
  r = HCg.h_recv
  if r >= 0
    got.push(r)
  end
  n += 1
end
HCg.h_close
l.detach
puts "out ok=#{ok} eperm=#{eperm} other=#{other} got=#{got.length}"
puts "out lens=#{lens(got)}"
puts "Out0=#{obj.map_get(Out, 0)} Out1=#{obj.map_get(Out, 1)}"
puts "leave=#{HCg.h_leave} exists=#{HCg.h_exists}"
