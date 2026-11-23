# E099 demo: read arbitrary kernel struct fields from a kprobe.
#
# `tcp_sendmsg(struct sock *sk, ...)` gives an untrusted `sk` pointer. kfield /
# kptr lower to BPF_CORE_READ (bpf_probe_read_kernel + CO-RE, BTF-driven), so
# reading sk->sk_sndbuf / sk->sk_rcvbuf is verifier-safe — a direct deref would
# be rejected outside trusted (struct_ops / fentry / lsm) contexts.
#
# Run it, make any TCP connection (e.g. `curl deb.debian.org`), then observe the
# last values read straight from the kernel:
#   # カーネルが保持する map 名は 15 文字までなので、この 2 本は
#   # どれも `u_kfield_demo_t` に見えて名前では区別できない。id で 1 本ずつ引く:
#   bpftool map show | grep u_kfield_demo_t
#   bpftool map dump id <上で出た id>
@calls = 0
@last_sndbuf = 0
@last_rcvbuf = 0

def kprobe__tcp_sendmsg(sk)
  @calls = @calls + 1
  # (A) explicit kfield builtin
  @last_sndbuf = kfield(sk, "sock", "sk_sndbuf")
  # (B) kptr typed handle + dot-accessor sugar
  s = kptr(sk, "sock")
  @last_rcvbuf = s.sk_rcvbuf
end

puts "[E099] kfield_demo loaded — kprobe tcp_sendmsg reading sk_sndbuf/sk_rcvbuf"
sleep 3600
