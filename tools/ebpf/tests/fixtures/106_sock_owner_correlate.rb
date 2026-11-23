# E296: socket-keyed process correlation. Solve E294's swapper/0 limit — external
# connects transition to ESTABLISHED in softirq context (current task = swapper/0),
# so emit_connect there records the wrong process. Fix: record the owning process at
# connect time (always process context) keyed by the sock ptr, then have emit_connect
# recover it by the same key (skaddr == sk, verified E296).
#
# sock_owner_set(sk) populates the per-unit sock->owner map; emit_connect correlates
# only when the unit uses sock_owner_set, so E294-only usage stays byte-identical.
# This sock-keyed map is the reusable substrate for E297 (send/recv latency pairing).
def kprobe__tcp_v4_connect(sk, uaddr, addr_len)
  sock_owner_set(sk)
  0
end

def tracepoint__sock__inet_sock_set_state(skaddr, daddr, dport, family, oldstate, newstate, daddr6_hi, daddr6_lo)
  if newstate == 1   # TCP_ESTABLISHED
    emit_connect(skaddr, daddr, dport, family, oldstate, daddr6_hi, daddr6_lo)   # E306: +oldstate/daddr6, 8-param -> caps
  end
  0
end
