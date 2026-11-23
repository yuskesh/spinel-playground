# M001 benchmark results — spinel HTTP/1.0 server vs nginx

The core numbers for the M001 achievement judgement set by
P001. Measured with
`benchmarks/harness/run_ab.sh` / `run_wrk.sh` and saved in the common CSV
([format specification](../../README.md#csv-format)).

## Environment

- Apple container (kernel 7.0.9-spinel-001, Apple Silicon, 4 CPU, debian:trixie)
- nginx alpine single worker, `access_log off`, `keepalive_timeout 0`, `listen 127.0.0.1:8080`
- spinel HTTP server M001 (`examples/http_server/M001/server.rb`, spinel-compiled native binary,
  single process, Connection: close)
- load gen and server run in the same container (to be separated at M003)

## Numbers

### Apache Bench (`ab -c N -n M`)

| concurrency | requests | tool | nginx RPS | **M001 RPS** | M001 / nginx | M001 p99 |
|---|---|---|---|---|---|---|
| 1   | 1000  | ab | 9,908.35  | **9,639.95**  | **97.3%** | 0 ms |
| 10  | 10000 | ab | 46,360.26 | **37,285.05** | **80.4%** | 1 ms |
| 100 | 10000 | ab | 49,880.54 | **39,200.62** | **78.6%** | 3 ms |

**0 failures** across all 10000 requests (meets "ab 0 failure" of P001 achievement judgement §4).

### wrk (5 seconds of sustained load, `--latency`)

| concurrency | duration | tool | nginx RPS | **M001 RPS** | M001 / nginx | nginx p99 | **M001 p99** |
|---|---|---|---|---|---|---|---|
| 10  | 5s | wrk | 65,856.06 | **47,813.24** | **72.6%** | 0.348 ms | 0.427 ms |
| 100 | 5s | wrk | 80,766.00 | **52,456.38** | **64.9%** | 1.90 ms  | 2.64 ms |

**0 socket errors / 0 non-2xx** in the 5-second wrk runs.

## Assessment

The M001 target P001 set was **"at least 10% of nginx"** (working first), but the
measurement reached **65 to 97%**. Reading the scores:

- **97% at c=1**: with serial processing the spinel HTTP server is effectively even with nginx.
  On the serial path of a single connection alone, the overhead of HTTP/1.0 Connection: close
  is at the same level for nginx too
- **80% at c=10**: as concurrency rises, nginx's epoll non-blocking advantage starts to show,
  but even spinel's blocking accept loop stays at about this level
- **65-79% at c=100**: the spinel server is single-process / single-thread blocking
  processing. The kernel absorbs the load in a backlog=128 queue while ab/wrk get in
  one after another by time slice. **Still just under 50k RPS**

"A single-process server compiled AOT from Ruby source to C delivers RPS from 2/3 of
nginx alpine up to nearly the same" — this is the power of AOT Ruby.

## M001 achievement declaration

P001 §M001 checklist (in the P001 roadmap, which is not part of this tree):

- [x] E033 (socket FFI) ✅
- [x] E034 (HTTP/1.0 parser) ✅
- [x] E035 (server MVP, 4 routes + malformed = 5 cases working) ✅
- [x] E036 (`ab` / `wrk` measurement + nginx comparison = this document) ✅
- [x] 200 from `curl http://localhost:8080/` ✅
- [x] 200 from `curl http://localhost:8080/health` ✅
- [x] 404 from `curl http://localhost:8080/notfound` ✅
- [x] **0 failure** with `ab -c 1 -n 1000 http://localhost:8080/` ✅
- [x] an nginx comparison bench is kept ✅

**→ M001 achieved.** Update the P001 status.

## Next milestone (M002)

With M001 established, move on to stacking the eBPF acceleration layer with XDP early
reject + L7 per-path counter (E037-E040). Expected effects:

- **early reject**: XDP_DROP packets from src IPs on the blocklist, preventing the TCP
  handshake itself → protects M001's performance against DDoS-type load
- **per-path counter**: keep per-path-hash counters in a BPF map and aggregate on the
  kernel side instead of streaming the access log to the host over ringbuf

When M002 is achieved, add an M002 column to this file and list the ratios against M001 / nginx.
