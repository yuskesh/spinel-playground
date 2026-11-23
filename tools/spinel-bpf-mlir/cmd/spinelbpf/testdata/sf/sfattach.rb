require "bpf"

# E126 H6: 実の attach — 自分の socketpair (AF_UNIX の SOCK_DGRAM — 網に触れない) の受け手に socket_filter を付け、長さ 1〜200 の datagram を 1 つずつ送り、
# 受けた長さの列を出す (filter が捨てた datagram も送り手には成功 — unix_dgram_sendmsg)。root (load と SO_ATTACH_BPF)
Out = BPF::ArrayMap.new("Out", :u32, 1)

def short_only(skb)
  n = skb.len
  Out.update(0, n)
  return BPF::SF_DROP if n > 64
  BPF::SF_KEEP
end
BPF.socket_filter :short_only

require "spinelbpf"

module HSock
  ffi_source <<~C
    #include <string.h>
    #include <fcntl.h>
    #include <unistd.h>
    #include <sys/socket.h>
    static int h_sv[2] = {-1, -1};
    static char h_buf[4096];
    /* AF_UNIX の SOCK_DGRAM の対 — [0] は filter を付ける受け手 (non-blocking)、[1] は送り手。網の設定に触れない */
    long h_pair(void) {
      if (socketpair(AF_UNIX, SOCK_DGRAM, 0, h_sv) != 0) return -1;
      if (fcntl(h_sv[0], F_SETFL, O_NONBLOCK) != 0) return -1;
      return h_sv[0];
    }
    long h_send(long n) {
      if (n < 0 || n > (long)sizeof h_buf) return -1;
      memset(h_buf, 120, (size_t)n);
      return (long)send(h_sv[1], h_buf, (size_t)n, 0);
    }
    /* 受けた datagram の長さ、無ければ -1 (EAGAIN) */
    long h_recv(void) { return (long)recv(h_sv[0], h_buf, sizeof h_buf, 0); }
  C
  ffi_func :h_pair, [], :long
  ffi_func :h_send, [:long], :long
  ffi_func :h_recv, [], :long
end

obj = SpinelBPF.load_embedded
fd = HSock.h_pair
if fd < 0
  raise "socketpair failed"
end
obj.attach_socket("short_only", fd)
puts "attached"
sent = 0
got = []
n = 1
while n <= 200
  if HSock.h_send(n) == n
    sent += 1
  end
  r = HSock.h_recv
  if r >= 0
    got.push(r)
  end
  n += 1
end
puts "sent=#{sent} got=#{got.length}"
puts "lens=#{got.map { |x| x.to_s }.join(",")}"
puts "out=#{obj.map_get(Out, 0)}"
