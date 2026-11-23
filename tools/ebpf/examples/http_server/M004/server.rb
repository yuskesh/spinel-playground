# examples/http_server/M004/server.rb
#
# M004 — kernel-side static response for GET /health via XDP_TX.
#
# Architecture (E046 candidate D):
#   - Kernel TCP stack handles the SYN/SYN-ACK/ACK handshake normally.
#   - When the client sends `GET /health ` as the first data packet, the XDP
#     program intercepts it at NIC ingress, rewrites it in place to be a
#     200 OK response (SEQ/ACK swap, MAC/IP/port swap, IP+TCP checksum
#     recompute), and returns XDP_TX so the response goes straight back.
#   - The original request packet is consumed by XDP — kernel never sees it.
#     The response carries the FIN flag, so the client closes the connection
#     and the kernel transitions through CLOSE_WAIT.
#   - Userspace workers do **only** `accept` + `close` (no `read`/`write`/
#     `recvfrom`/`sendto` ever). That's P001 §M004 ② in the E046-revised form.
#
# Non-`/health` traffic falls through XDP_PASS to the kernel TCP stack, and
# the M003 multi-worker code path handles it. (For E047 MVP we keep the
# server `/health`-only — non-matching connections accept+close immediately,
# clients receive nothing. M003 hybrid is left to E048.)
#
# Build:
#   spinel-ebpf compile examples/http_server/M004/server.rb \
#       -o build/m004_server --build
# Run:
#   SPINEL_XDP_IFACE=lo SPINEL_HTTP_WORKERS=4 ./build/m004_server/server
#   curl http://127.0.0.1:8080/health
#   strace -p <worker> -e read,write,recvfrom    # should show nothing

module Net
  ffi_func :sp_net_listen,                [:int, :int],    :int
  ffi_func :sp_net_accept,                [:int],          :int
  ffi_func :sp_net_close,                 [:int],          :int
  ffi_func :sp_net_fork,                  [],              :int
  ffi_func :sp_net_getpid,                [],              :int
end

XDP_PASS = 2
XDP_TX   = 3

@xdp_match_hits = 0
@xdp_pass_hits  = 0

# E047: M004 XDP fast-path program.
# If the incoming frame is `GET /health `, hand-craft the response and bounce
# it back via XDP_TX. Otherwise let it proceed to the kernel TCP stack so the
# accept-loop below can clean up.
#
# E050 update: the underlying xdp_reply_health helper now correctly handles
# TCP headers with options (thl=32 with Timestamps). The prior E047 code
# silently fell through to XDP_PASS for option-bearing packets — which is
# essentially every real Linux packet. This raised concurrent throughput
# significantly while leaving sequential reliability ~50% (still bound by
# the kernel TCP state divergence documented in E049).
def xdp__health_responder
  if xdp_match_health == 1
    @xdp_match_hits = @xdp_match_hits + 1
    xdp_reply_health
  else
    @xdp_pass_hits = @xdp_pass_hits + 1
    XDP_PASS
  end
end

# Accept-only worker. The actual request/response handling happens entirely
# in the XDP program above; this loop just keeps the accept queue drained so
# the kernel keeps accepting new connections. We deliberately do NOT call
# read/write — that's the whole point of M004.
def worker_loop(port)
  listen_fd = Net.sp_net_listen(port, 1)
  if listen_fd < 0
    puts "[worker " + Net.sp_net_getpid.to_s + "] listen failed"
    exit(1)
  end
  puts "[worker " + Net.sp_net_getpid.to_s + "] M004 accept-only loop ready"
  loop do
    client = Net.sp_net_accept(listen_fd)
    break if client < 0
    # M004 contract: no read/write here. XDP already did the conversation.
    Net.sp_net_close(client)
  end
end

# ---- main ----

port    = (ENV["SPINEL_HTTP_PORT"]    || "8080").to_i
workers = (ENV["SPINEL_HTTP_WORKERS"] || "4").to_i
if workers < 1
  workers = 1
end

puts "[main " + Net.sp_net_getpid.to_s + "] M004 starting " + workers.to_s + " accept-only worker(s) on port " + port.to_s

i = 1
while i < workers
  pid = Net.sp_net_fork
  if pid < 0
    puts "[main] fork failed"
    exit(1)
  end
  if pid == 0
    break
  end
  i = i + 1
end

worker_loop(port)
