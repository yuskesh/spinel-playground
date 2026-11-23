# E242 S4/S5: OBI サブセット — eBPF で RED metrics を収集し Prometheus /metrics 公開。
#
# カーネル側 (eBPF): do_sys_openat2 の latency を kprobe/kretprobe で計測し
#   spnl_emit_pair(svc, latency_ns) で ringbuf に流す。
# ユーザ空間 (Ruby): on_emit_pair で RED 集計。**S5: epoll 多重化** — consumer の
#   ringbuf epoll fd を listen fd と同じ epoll に載せ、イベント到着毎に drain
#   (scrape を待たないので overflow しない、ADR-007 §7 source-contributing)。
#   graceful shutdown は sp_net_epoll_wait_one が SIGINT/TERM で -1 を返すことで成立。
#
# build: bin/spinel-ebpf compile examples/observability/red_metrics.rb --build -o build
# run:   SPINEL_HTTP_PORT=9100 ./build/red_metrics &
#        curl -s localhost:9100/metrics
use_plugin :ebpf

module Net
  ffi_func :sp_net_listen,         [:int, :int], :int
  ffi_func :sp_net_accept,         [:int],       :int
  ffi_func :sp_net_read_line,      [:int],       :str
  ffi_func :sp_net_write_str,      [:int, :str], :int
  ffi_func :sp_net_rl_close,       [:int],       :int
  ffi_func :sp_net_epoll_create,   [],           :int
  ffi_func :sp_net_epoll_add,      [:int, :int], :int
  ffi_func :sp_net_epoll_wait_one, [:int],       :int
  ffi_func :sp_net_install_term_handlers, [],    :int   # SIGINT/TERM -> shutdown flag
end

module Consumer
  ffi_func :spnl_consumer_epoll_fd, [], :int   # ringbuf epoll fd to multiplex
end

@count  = 0
@sum_ns = 0
@max_ns = 0

# --- kernel: openat latency (E083) -> ringbuf (svc=0, dur_ns) ---
def kprobe__do_sys_openat2
  latency_start
end

def kretprobe__do_sys_openat2(ret)
  spnl_emit_pair(0, latency_end)
end

# --- userspace: RED aggregation (1 イベント毎、フル Ruby) ---
on_emit_pair do |svc, dur_ns|
  @count  = @count + 1
  @sum_ns = @sum_ns + dur_ns
  @max_ns = dur_ns if dur_ns > @max_ns
end

def metrics_body
  "# HELP spnl_openat_total openat calls observed via eBPF.\n" +
  "# TYPE spnl_openat_total counter\n" +
  "spnl_openat_total " + @count.to_s + "\n" +
  "# HELP spnl_openat_latency_ns_sum sum of openat latencies (ns).\n" +
  "# TYPE spnl_openat_latency_ns_sum counter\n" +
  "spnl_openat_latency_ns_sum " + @sum_ns.to_s + "\n" +
  "spnl_openat_latency_ns_max " + @max_ns.to_s + "\n"
end

port = (ENV["SPINEL_HTTP_PORT"] || "9100").to_i
listen_fd = Net.sp_net_listen(port, 0)
if listen_fd < 0
  puts "[red] listen failed"
  exit(1)
end

Net.sp_net_install_term_handlers          # SIGINT/TERM -> graceful loop exit
ep  = Net.sp_net_epoll_create
Net.sp_net_epoll_add(ep, listen_fd)
rfd = Consumer.spnl_consumer_epoll_fd
Net.sp_net_epoll_add(ep, rfd)
puts "[red] /metrics on 127.0.0.1:" + port.to_s + " (epoll mux listen=" + listen_fd.to_s + " ring=" + rfd.to_s + ")"

loop do
  fd = Net.sp_net_epoll_wait_one(ep)
  break if fd < 0                       # SIGINT/TERM -> graceful shutdown
  if fd == rfd
    consume_events(0)                   # drain ready ringbuf records -> RED (continuous)
  else
    client = Net.sp_net_accept(listen_fd)
    if client >= 0
      Net.sp_net_read_line(client)      # request line (this demo serves /metrics for any path)
      loop do
        line = Net.sp_net_read_line(client)
        break if line.length == 0
      end
      body = metrics_body
      resp = "HTTP/1.0 200 OK\r\n" +
             "Content-Type: text/plain; version=0.0.4\r\n" +
             "Content-Length: " + body.length.to_s + "\r\n" +
             "Connection: close\r\n\r\n" + body
      Net.sp_net_write_str(client, resp)
      Net.sp_net_rl_close(client)
    end
  end
end
puts "[red] shutdown"
