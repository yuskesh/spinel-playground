# E075: spinel vs CRuby vs nginx HTTP server benchmark

Numbers for the 3-way comparison benchmark described in detail in the
E075 Edoc. Measured with
`benchmarks/harness/run_{ab,wrk}.sh`; the common CSV
([format](../../README.md#csv-format)) is saved in [`raw.csv`](raw.csv).

## Environment (common to all servers)

- Apple container `e049`, kernel 7.0.9-spinel-002 (`CONFIG_NET_SCH_NETEM=y`)
- debian:trixie, ruby 3.3.8 (CRuby), spinel-ebpf HEAD (as of f519fe6)
- load gen and server run in the same container
- sysctl set beforehand (common to CRuby and spinel):
  - `net.ipv4.tcp_tw_reuse=1`
  - `net.ipv4.tcp_fin_timeout=10`
  - `net.ipv4.ip_local_port_range="10000 65000"`
- HTTP/1.0 + `Connection: close` + the same routes (`/` → 200 hello, `/health` → 200 OK)

## Targets

| Label | Implementation | Summary |
|---|---|---|
| `cruby_M001` | `benchmarks/targets/cruby_m001_server.rb` | plain Ruby, TCPServer + accept loop, single process |
| `cruby_M003_wN` | `benchmarks/targets/cruby_m003_server.rb` | plain Ruby, `fork × N` + `SO_REUSEPORT` |
| `spinel_M001` | `examples/http_server/M001/server.rb` (via spinel-ebpf) | spinel-compiled AOT, single process |
| `spinel_M003_wN` | `examples/http_server/M003/server.rb` (via spinel-ebpf) | spinel-compiled AOT, `fork × N` + `SO_REUSEPORT` |

## Numbers

### Apache Bench (`ab -c N -n 10000`)

| target           | c=10 RPS  | c=100 RPS | c=100 p99 (ms) | failures |
|------------------|-----------|-----------|----------------|----------|
| spinel_M001      | 39,092    | 43,689    | 3              | 0        |
| **cruby_M001**   | **57,673** | **67,824** | **2**         | 0        |
| spinel_M003 (w=4)| 42,272    | 59,048    | 2              | 0        |
| cruby_M003 (w=4) | 40,774    | 58,156    | 2              | 0        |

### wrk (`wrk -c N -d {5..10}s --latency`)

| target           | c   | duration | RPS       | p50 (ms) | p99 (ms) | failures |
|------------------|-----|----------|-----------|----------|----------|----------|
| spinel_M001      | 10  | 5s       | 58,362    | 0.136    | 0.264    | 0        |
| spinel_M001      | 100 | 5s       | 63,976    | 1.41     | 1.93     | 0        |
| **cruby_M001**   | 10  | 5s       | **71,887** | 0.100   | 0.269    | 0        |
| **cruby_M001**   | 100 | 5s       | **81,202** | 1.10    | 1.65     | 0        |
| spinel_M003 (w=2)| 100 | 10s      | 108,543   | 0.750    | 2.48     | 0        |
| spinel_M003 (w=4)| 100 | 10s      | 112,016   | 0.684    | 2.55     | 0        |
| spinel_M003 (w=8)| 100 | 10s      | 119,103   | 0.590    | 2.40     | 0        |
| cruby_M003 (w=4) | 100 | 10s      | 120,518   | 0.609    | 2.31     | 0        |
| **cruby_M003 (w=8)** | 100 | 10s  | **126,372** | 0.502  | 2.34     | 0        |

## Observations

### 1. **Single-process CRuby beats spinel M001**

With `wrk c=100 d=5s`: **CRuby 81k vs spinel 64k (≈ 1.27×)**. spinel-ebpf's FFI
(`sp_net_*` through libspinel_rt.a) adds an overhead of a few hundred ns per
syscall, while CRuby's `TCPServer`/`IO#gets` call the syscalls directly from a C extension.
In a connection-per-request workload such as HTTP/1.0 the number of accept/read/write/close
syscalls dominates, so this difference shows.

### 2. **With 4 workers the two are nearly even**

With `wrk c=100 d=10s w=4`: **spinel 112k vs CRuby 120k (≈ 1.07×)**.
Kernel-side fanout through SO_REUSEPORT becomes the dominant term, and the difference
in per-request cost between Ruby and the spinel-compiled binary becomes hard to see.

### 3. **Both level off at w=8 (≈ 120-130k)**

A single-host bench with ab/wrk over loopback in the same container hits the system limit
of ephemeral ports / TCP state management at around **~120-130k RPS**. With the 4-CPU
configuration inside the Apple container, worker IPC / lock contention dominates from w=4 up.

### 4. **spinel shows no advantage in the M001/M003 comparison**

Compared as a "plain HTTP server" only, spinel-ebpf is slower than CRuby (M001) or
even with it (M003). **The real value of spinel-ebpf is in M004 (the pure-XDP TCP slice)**:
zero data-plane syscalls, no worker process, and 60-72k RPS at ab c=10 drawn from a single
Ruby method (E054).
CRuby cannot attach XDP by construction, so it is not a comparison target there.

## Conclusion

- **For Ruby + a plain TCP socket, CRuby is fast enough** (loopback 120k RPS @ 8w)
- **The point of spinel-ebpf is "using Ruby as a kernel-side language"**;
  in pure userspace HTTP server performance its advantage over CRuby is thin (M001) or absent (M003)
- To speak seriously about the "performance" axis of the ADR-005 mission ("implement an HTTP
  server with spinel + eBPF and demonstrate its performance and expressiveness"), the
  honest comparison is the M004 (pure-XDP) bench

## Addendum: M004 pure-XDP vs CRuby `/health`

The "plain HTTP server" comparison (above) shows no advantage for spinel-ebpf, but **M004's
pure-XDP TCP slice** is an area CRuby cannot write by construction. An apples-to-apples
comparison restricted to `/health`:

| target           | tool | concurrency | RPS    | latency (mean) | failures |
|------------------|------|-------------|--------|----------------|----------|
| **m004_xdp**     | ab   | 1, n=200    | **88,967** | **0.011 ms**  | 0 |
| m004_xdp         | ab   | 1, n=1000   | 72,400 | 0.014 ms       | 0 |
| m004_xdp         | ab   | 1, n=2000   | 63,777 | 0.016 ms       | 0 |
| m004_xdp         | ab   | 10, n=2000  | 75,250 | 0.13 ms        | 0 |
| cruby_M001       | ab   | 1, n=500    | 8,779  | 0.114 ms       | 0 |
| cruby_M001       | ab   | 10, n=2000  | 35,866 | 0.279 ms       | 0 |

### Ratio

| concurrency | M004 RPS | CRuby RPS | **M004 / CRuby (factor)** |
|-------------|----------|-----------|---|
| c=1         | 63,777   | 8,779     | **7.3×** (10.1× in fresh state) |
| c=10        | 75,250   | 35,866    | **2.1×** |

### latency

| concurrency | M004 mean | CRuby mean | M004 / CRuby |
|-------------|-----------|------------|---|
| c=1         | 0.011-0.016 ms | 0.114 ms | **7-10× lower** |
| c=10        | 0.13 ms   | 0.279 ms   | **2.1× lower** |

### Explanation

M004 (the pure-XDP TCP slice) **bypasses the kernel TCP stack completely**:

- incoming SYN/data/FIN are all handled at the XDP hook (`bpf_tcp_raw_gen_syncookie_ipv4`)
- the response is sent directly with XDP_TX (NIC RX → same NIC TX, no kernel skb path)
- the userspace process **never calls** accept/read/write/close
  (confirmed with strace too)
- per-flow state is only the `bpf_conntab` LRU map

CRuby (`TCPServer`) goes through the kernel TCP stack:

- each request is accept/read×N/write/close = ~4-6 syscalls
- passes through the kernel skb stack (route lookup / filter / qdisc)
- ruby IO bridge + GC pressure
- the single-thread accept loop waits one round trip per request even at c=1

At c=1 **M004 is 7-10× faster than CRuby** because the number of syscalls per request is
the dominant term. The gap narrows at c=10 because batching helps the CRuby side too
(though, as a single process, its parallelism is limited).

### Confirmation

Running strace on the M004 process while hitting `/health` 30 times shows
**zero accept4 / read / write / recvfrom / sendto / close calls**:

```bash
$ strace -e trace=accept4,read,write,recvfrom,sendto,close -c -p $(pidof tcp_slice)
strace: Process 9133 attached
(curl 30 times in parallel)
strace: Process 9133 detached
# (no syscall count table emitted = 0 events)
```

`/proc/net/tcp` has no listen socket on :8080 either:

```bash
$ awk '{printf "%s %s %s\n", $2, $3, $4}' /proc/net/tcp | grep ':1F90 ' || echo "no listener"
no listener
```

This is what "an HTTP server written in Ruby **completes on the kernel side**" means. CRuby's
TCPServer has no means to achieve this by construction, so it is on a different level from
the userspace comparison in the upper half of E075.

## Conclusion (final)

An honest evaluation in 3 steps:

1. **CRuby vs spinel-compile (userspace only)**: CRuby is 1.27× faster (overhead from going through the FFI)
2. **CRuby M003 vs spinel M003 (multi-worker)**: nearly even (SO_REUSEPORT is the dominant term)
3. **CRuby vs spinel M004 pure-XDP** (`/health`): **spinel-ebpf is 2-10× faster** (kernel TCP bypass)

The "**performance**" axis of the ADR-005 mission is claimed with (3); (1) and (2) are listed honestly alongside.
DSL expressiveness (E070-E074) is a value axis independent of this.

## Related

- E054 pure-XDP TCP slice codegen
- [M001 nginx baseline bench](../M001/summary.md)
- [M003 nginx parity bench](../M003/summary.md)
