# E188 benchmark: auto kernel-cache (pure-XDP) vs userspace spinel HTTP server

- **Date**: 2026-06-17
- **Environment**: Apple container `spnlbuild` (debian:trixie, Linux 7.0.12-spinel-005), the `lo` interface,
  **generic (SKB-mode) XDP**, 5 CPUs. tool: `ab` (apache2-utils). `tcp_tw_reuse=1`.
- **What is compared (both spinel-compiled, the same machine, the same lo, connection-per-request / HTTP/1.0 close)**:
  - **A) kernel-cache**: `examples/http_server/kernel_cache_demo/ping.rb` (`kernel_cache "/ping", body`,
    zero hand-written eBPF). The pure-XDP TCP slice **completes** SYN/data/FIN **inside the kernel**, and serves `/ping`
    from `bpf_kc_resp`. **There is no listen socket on :8080**. Response check: `PONG (...runtime...)`.
  - **B) userspace**: `examples/http_server/M001/server.rb` (a single-process accept loop,
    `read_line`→`write`→`close`). Serves `/`. Response check: `hello`.

## Results (mean = `ab`'s Time per request; lower is better)

| Setup | c | RPS | mean latency | complete / fail |
|---|---|---|---|---|
| **A) kernel-cache** | 1  | **48,009** | **0.021 ms** | 2000 / 0 |
| B) userspace M001   | 1  | 13,444     | 0.074 ms     | 2000 / 0 |
| **A) kernel-cache** | 10 | **85,886** | 0.116 ms     | 5000 / 0 |
| B) userspace M001   | 10 | 74,171     | 0.135 ms     | 5000 / 0 |

- **c=1**: kernel-cache has **about 3.6× the RPS** of userspace, and latency **about 3.5× lower** (0.021ms vs 0.074ms).
  = the effect of removing the userspace round trip (accept/read_line/write/close) and FFI marshalling (`sp_str_dup_external`, E075/E186)
  from the data plane entirely.
- **c=10**: the difference converges to **about 1.16×**. **Generic (SKB-mode) XDP on `lo` serializes under high concurrency**, so
  kernel-cache's scaling tops out (the same constraint as E056). Userspace tops out too, as a single process.

## Interpretation and honest caveats

- **The kernel path wins big at low concurrency and converges at high concurrency** — the same shape as E075 (M004 pure-XDP vs CRuby: 7–10× at c=1, 2.1× at c=10).
  This cache is M004 **generated automatically by the compiler**, so it shows the same character as the hand-written M004.
- Measured on `lo` + **generic XDP (SKB-mode)**. A production **multi-queue NIC + native XDP** should spread across
  RX queues even under high concurrency and converge less (E066/E108 established the codegen capability; real multi-queue hardware has not been measured).
- `ab`'s p50/p99 have 1ms resolution, so sub-ms values round to 0. Latency uses `Time per request (mean)`.
- The response bodies differ slightly, A=`PONG (...)` and B=`hello`, but both are small and **the data path's cost dominates**.
- A completes the handshake through FIN in XDP for each connection (0 syscalls). B runs accept/read/write/close every time.

## Conclusion

**The auto kernel-cache generated from a 1-line declaration (zero hand-written eBPF) gives, against the same spinel userspace server,
~3.6× the RPS and ~3.5× lower latency at low concurrency**. E188's aim of removing FFI marshalling is confirmed in numbers.
High concurrency converges from lo/SKB-mode serialization, so re-measuring with native XDP + multi-queue is the next task.

## An attempt to re-measure with native XDP / multi-queue (2026-06-17) — native XDP measured on the STM32 onboard NIC

An attempt to measure "the high-concurrency convergence should disappear with native XDP + multi-queue". At first every environment had a blocker,
but **native-XDP was measured on the STM32MP257F-DK's onboard NIC (stmmac, 2 RX queues) + a cross-BTF deploy (E189)**.
Details are in the E189 Edoc and at the end of this section.

The table below is how far each environment got (the STM32 row is updated from an initial wrong assumption to a successful measurement):

| Environment | kernel/BTF/tools | NIC | native XDP | Verdict |
|---|---|---|---|---|
| Apple container `lo` | 7.0.12 / BTF / complete | loopback | **impossible** (lo has no native XDP) | generic only (= this benchmark) |
| Apple container `eth0` | as above | virtio_net 1-queue | **impossible**: `rx-gro-hw: on [fixed]` / `rx-checksumming: on [fixed]` cannot be disabled in the guest (`Could not change any device features`). virtio_net native XDP requires GRO_HW off | ✗ |
| Apple container `veth` | as above | veth pair | **attach succeeds natively** (`driver id`), XDP_PASS also needed on the peer. But **XDP_TX does not reliably reach the peer** (1 curl gives SYN_RX=3/SYNACK_TX=3=SYN retransmissions; ab gives 3.42 RPS, median 210ms = the TCP RTO penalty) | △ works, but perf is meaningless |
| STM32MP257F-DK (192.0.2.**25**, onboard) | 6.6.48 **non-RT (PREEMPT)** / no BTF / bpftool present, no clang / **SYN_COOKIES=y + the syncookie helper exists** | **onboard `end0`=st_gmac, 2 RX / 4 TX queues**, directly on the LAN (the initial USB r8152 1-queue was the wrong connection) | **✅ success (native/drv mode)** | ✅ load with cross-BTF (7.0.12) → native XDP attach → curl 200. See the benchmark below |
| FRDM-i.MX95 (192.0.2.24) | **6.18.2-rt3** arm64 (NXP Real-time Edge 3.4) / **BTF present** / bpftool+clang present | nxp_enetc4 **6-queue**, directly on the LAN | **impossible** (below; needs a kernel rebuild) | ✗ the hardware is ideal, but **bpf_timer is unavailable under PREEMPT_RT** + `CONFIG_SYN_COOKIES` disabled |
| WSL2 (192.0.2.23) | 6.18 / BTF / tools | hv_netvsc **16-queue** | (not reached) | △ 8080 not reachable through NAT, XDP_TX unreliable with hv_netvsc+NAT, x86_64 cross-build |

**The (old) conclusion is withdrawn**: "only the Apple container can load kernel-cache" was wrong. **native XDP was measured on the STM32 onboard NIC
by a cross-BTF deploy (E189)** (below). That the Apple container cannot do native is unchanged.

### STM32 onboard `end0` native-XDP benchmark (2026-06-17) — E189

With cross-BTF (the 7.0.12 BTF supplied through `btf_custom_path`), kernel-cache's `.bpf.o` was loaded on the STM32's 6.6.48 (no BTF),
**attached to the onboard stmmac `end0` (2 RX / 4 TX queues) as native (drv) XDP**, and measured with `ab` from the Mac (1GbE LAN,
connection-per-request). **native and generic (SKB) are compared** on the same NIC:

| c | **native** RPS | **generic** RPS | Notes |
|---|---|---|---|
| 1   | 1,476  | 1,359  | bound by the LAN RTT (~0.68ms), 0 fail |
| 10  | 13,327 | 12,830 | 0 fail |
| 100 | 14,179 | 15,495 | 0 fail (n=2000) |

- **native ≈ generic (a ±5% difference, within noise)**. But **every number here is the peak of a short `ab` burst, not sustained throughput**.
- **[Important, correction 1] "CPU-bound (2×A35)" was a wrong inference**. Measured with `mpstat -P ALL`, **the board is mostly idle even under load**
  (CPU0 averages ~4% / peaks at 31%=softirq, CPU1 idle, `end0` IRQs ~134–188/s, bandwidth <1% of 1GbE). **Not CPU-, IRQ- or bandwidth-bound**.
  That c=1 is RTT-bound (1476≈1/0.66ms ping) is backed up.
- **[Important, correction 2] The real limit is "it cannot be sustained"** (shown with wrk/hey + burst-vs-sustained from the same client):
  an `ab` burst at c=100 n=2000=**14,919 RPS**, but the same `ab` **sustained at c=100 -t10 = a complete stall**. `wrk -t8 -c100 -d12s`=
  409 RPS (read errors, `0.00B read` = the HTTP/1.0-close vs keepalive mismatch, so the number is invalid), `hey -disable-keepalive`=18 RPS (0 successes).
  **The board is idle even during the collapse** → it is **a limit of connection handling**, not compute or the wire. The strongest candidate (strongly suggested): **the conntab (a 4-tuple LRU) +
  a per-connection `bpf_timer` (holding E057's RESP/CLOSED for seconds) collides with source-port reuse under sustained load → a new SYN collides with stale state
  and the handshake fails → stall**. A burst finishes before the ports wrap around; sustained load wraps around and collides. `wrk` assumes HTTP/1.1 keepalive,
  so it does not suit this server (many read errors). **Confirming it needs a conntab dump during sustained load / a shorter TTL / a different client port range**.

**What was reached, and what is unresolved**:
- ✅ **A cross-kernel CO-RE deploy works on real hardware** (E189): kernel-cache's `.bpf.o` built on 7.0.12 loads, attaches and serves curl 200 on the STM32's 6.6.48
  (no native BTF). Done with 1 `SPNL_BTF_PATH`, and reusable.
- ✅ **kernel-cache works with native XDP on a real multi-queue NIC (a functional demonstration)**: it completes the handshake through FIN in the kernel,
  answers on the real wire with XDP_TX, has no :8080 listener, and **has 0 fail up to c=100 in a burst**. **The first measurement of a native-XDP data plane**.
- ❌ **But it cannot handle sustained load** (correction 2 above). So on the STM32 a comparison of sustained throughput cannot be made at all, and
  **"does native multi-queue remove the high-concurrency convergence" is still unresolved**. Measuring it needs **a fast multi-core machine + a real server NIC +
  a slice that can be sustained (tolerant of conntab/timer churn) + keepalive support, or a loadgen that tolerates sustained conn-per-req**.
- Note: the spinel-compiled `routes` itself segfaulted in the spinel GC runtime's constructor under a foreign glibc + an explicit loader,
  so the data plane was measured with **a minimal C loader (`kcload`) that reads the same `routes.bpf.o`** (what is measured = the XDP data path is the same).

### i.MX95 cross-deploy measurement (2026-06-17) — crossing kernels with CO-RE works; the kernel lacks 2 features

Unlike the initial assumption (no BTF, no tools), the i.MX95 runs **NXP Real-time Edge Distro 3.4** with **BTF present (`/sys/kernel/btf/vmlinux`),
bpftool and clang complete**. `routes` (E188 multi-route), built in the Apple container (7.0.12), was cross-deployed:

- **Crossing kernels with CO-RE works**: bundling the interpreter (a symlink to `/usr/lib/ld-linux-aarch64.so.1`) and a newer `libbpf.so.1` (1.5; the board has 1.2.2)
  made the binary start, and **the `.bpf.o` produced on 7.0.12 was relocated against the i.MX95's 6.18-rt BTF, with the verifier passing up to insn 88**
  (= confirms that a CO-RE deploy between different kernels really works).
- **But 2 missing kernel features prevent loading / running** (confirmed with `bpftool` / the verifier log):
  1. **`bpf_timer` is rejected under PREEMPT_RT** (settled): the verifier reports, at `88: call bpf_timer_cancel`,
     **`bpf_timer cannot be used for PREEMPT_RT`**, and `failed to load: -95` (EOPNOTSUPP). The i.MX95 runs an RT kernel (`6.18.2-rt3`).
     kernel-cache's TCP slice embeds `bpf_timer` for connection-state TTL / retransmission (E057), so it fails here, at load.
  2. **`CONFIG_SYN_COOKIES is not set`** (checked in the config): the feature that `bpf_tcp_raw_gen_syncookie_ipv4`, the core of the pure-XDP slice, needs
     is disabled. Even if the timer were removed to pass load, syncookie generation would not work and the handshake could not complete.

**i.MX95 finding**: the hardware (6-queue nxp_enetc4, directly on the LAN) is ideal for measuring native XDP, but **the stock RT kernel cannot
load / run kernel-cache**. Getting native XDP + multi-queue numbers needs **a rebuilt i.MX95 kernel** (non-RT or a configuration that allows bpf_timer +
`CONFIG_SYN_COOKIES=y`) — a separate task of the same class as E001/E179. **Gained**: the cross-kernel CO-RE deploy itself is shown to work.

**Can switching to non-RT in U-Boot avoid this? → No (checked with IKCFG)**: the board has, on another rootfs (mmcblk0p2), **a non-RT 6.18 stock
NXP kernel** (`Image-6.18.2-1.0.0-gf49f45233f7b`, 36MB), and U-Boot might be able to change what boots. But
that non-RT image's embedded config (`IKCFG_ST`, extracted) **has `CONFIG_BPF_SYSCALL=y`/`CONFIG_BPF_JIT=y` but
neither `CONFIG_DEBUG_INFO_BTF` nor `CONFIG_SYN_COOKIES`**. Its size (36MB) is of the same class as the RT image before BTF was added (`Image.bak-pre-ftrace`, 35MB),
and against the current RT image with BTF (53MB) it lacks about 10MB of BTF. ⇒ Switching to non-RT **removes the RT/bpf_timer blocker but
leaves no BTF (no CO-RE → the `.bpf.o` cannot load), and SYN_COOKIES is still missing** = worse, if anything. **Conclusion: there is no way other than flashing a single kernel that satisfies non-RT base + BTF +
`CONFIG_SYN_COOKIES=y` at once**. The board has a history of re-flashing BTF/ftrace/DT
(`Image.bak-pre-btf` and others), so the rebuild path exists, but it is a separate task.
