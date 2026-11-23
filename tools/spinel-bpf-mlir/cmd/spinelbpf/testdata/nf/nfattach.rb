require "bpf"

# E128 H6: 実の attach — 自分だけの netns (unshare(CLONE_NEWNET)) の lo で、IPv4 の LOCAL_OUT に netfilter を付け、127.0.0.1 の UDP の対 (unshare の後に作る) で
# payload 1〜200 を 1 つずつ送る。attach は netns の inode が unshare の前と違うときだけ (追補 1)。host の netns には付けない。root
NfState = Struct.new(:hook, :pf)
BPF.kernel_type(NfState, "nf_hook_state", hook: :u8, pf: :u8)
StateT = BPF::KernelType.new(NfState.new(0, 0))
Skb = Struct.new(:len)
BPF.kernel_type(Skb, "sk_buff", len: :u32)
SkbT = BPF::KernelType.new(Skb.new(0))

Out = BPF::ArrayMap.new("Out", :u32, 4)

def small_only(ctx)
  st = ctx.state(StateT)
  sk = ctx.skb(SkbT)
  n = sk.load.len
  Out.update(0, st.load.hook)
  Out.update(1, st.load.pf)
  Out.update(2, n)
  Out.atomic_add(3, 1)
  return BPF::NF_DROP if n > 64
  BPF::NF_ACCEPT
end
BPF.netfilter :small_only

require "spinelbpf"

module HNf
  ffi_source <<~C
    #include <string.h>
    #include <errno.h>
    #include <fcntl.h>
    #include <poll.h>
    #include <unistd.h>
    #include <sys/stat.h>
    #include <sys/ioctl.h>
    #include <sys/socket.h>
    #include <net/if.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    int unshare(int flags);
    #ifndef CLONE_NEWNET
    #define CLONE_NEWNET 0x40000000
    #endif
    static int h_rs = -1, h_ss = -1;
    static struct sockaddr_in h_dst;
    static char h_buf[4096];
    /* この thread の netns の inode */
    long h_netns(void) { struct stat st; return stat("/proc/thread-self/ns/net", &st) == 0 ? (long)st.st_ino : -1; }
    /* 自分だけの新しい netns に移り、その lo を up にする (0 は成功) — process が終われば netns は消える */
    long h_unshare(void) {
      struct ifreq r;
      if (unshare(CLONE_NEWNET) != 0) return -errno;
      int s = socket(AF_INET, SOCK_DGRAM, 0);
      if (s < 0) return -2;
      memset(&r, 0, sizeof r);
      strcpy(r.ifr_name, "lo");
      if (ioctl(s, SIOCGIFFLAGS, &r) != 0) { close(s); return -3; }
      r.ifr_flags |= IFF_UP | IFF_RUNNING;
      if (ioctl(s, SIOCSIFFLAGS, &r) != 0) { close(s); return -4; }
      close(s);
      return 0;
    }
    /* 127.0.0.1 の UDP の受け手と送り手 — unshare の後に作る */
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
    long h_send(long n) {
      if (n < 0 || n > (long)sizeof h_buf) return -EINVAL;
      memset(h_buf, 120, (size_t)n);
      long r = (long)sendto(h_ss, h_buf, (size_t)n, 0, (struct sockaddr *)&h_dst, sizeof h_dst);
      return r < 0 ? -errno : r;
    }
    long h_recv(void) {
      struct pollfd p = {h_rs, POLLIN, 0};
      if (poll(&p, 1, 20) != 1) return -1;
      return (long)recv(h_rs, h_buf, sizeof h_buf, MSG_DONTWAIT);
    }
  C
  ffi_func :h_netns, [], :long
  ffi_func :h_unshare, [], :long
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

obj = SpinelBPF.load_embedded
before = HNf.h_netns
u = HNf.h_unshare
after = HNf.h_netns
moved = 0
if u == 0 && before > 0 && after > 0 && after != before
  moved = 1
end
puts "netns before=#{before} after=#{after} moved=#{moved}"
if moved != 1
  raise "not in a new netns (unshare #{u}) — the netfilter program is not attached (E128)"
end
l = obj.attach_netfilter("small_only", 2, 3, 0)
if HNf.h_sockets != 0
  raise "sockets failed"
end
ok = 0
eperm = 0
other = 0
got = []
n = 1
while n <= 200
  r = HNf.h_send(n)
  if r == n
    ok += 1
  elsif r == -1
    eperm += 1
  else
    other += 1
  end
  r = HNf.h_recv
  if r >= 0
    got.push(r)
  end
  n += 1
end
HNf.h_close
l.detach
puts "sent ok=#{ok} eperm=#{eperm} other=#{other} got=#{got.length}"
puts "lens=#{lens(got)}"
puts "Out0=#{obj.map_get(Out, 0)} Out1=#{obj.map_get(Out, 1)} Out2=#{obj.map_get(Out, 2)} runs_ge_200=#{obj.map_get(Out, 3) >= 200}"
