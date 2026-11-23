# Benchmark methodology audit (2026-06-17)

E189 found that "kernel-cache's ~14k RPS is a **burst peak** and collapses under sustained load (the board is idle = not CPU- or bandwidth-bound)". In response, **the way every past benchmark measured was audited**. For each claim, "**how it was measured**", not "the number itself", is extracted from the Edoc / summary / harness script / server source, and the number is judged to represent either **the server's real capacity** or **a measurement artefact** (a burst peak / loadgen-bound / a connection-model mismatch).

> The conclusion in one line: **every absolute RPS should be treated as "the peak this condition produced". What can be trusted is "the relative ratio of spinel-vs-nginx or before/after under the same conditions"**, not absolute throughput or "the server's limit". **The only measurement that measured sustained load correctly is E186/R2's before/after (30s).**

## Legend

| Mark | Meaning |
|---|---|
| 🟢 SOLID | sustained + controlled. Trustworthy as a relative figure too |
| 🟡 RELATIVE-only | A same-condition A/B is fair. But the absolute value is unproven (loadgen / lo / no saturation check) |
| 🟠 BURST-peak | An `ab -n <fixed count>` burst. Not sustained capacity |
| 🔵 SEQUENTIAL-only | c=1 correctness. Says nothing about concurrency or throughput |
| 🔴 SUSPECT | loadgen-bound / a known misreading / an invalid measurement regime |
| ⚪ N/A | Not a performance claim (a demonstration of a mechanism or of correctness) |

## Audit table

| # | Claim (summary) | tool / form | connection | loadgen | server saturation checked | client sysctl | errors | verdict |
|---|---|---|---|---|---|---|---|---|
| M001 | c=1/c=10 ab, 97/80% of nginx | ab **burst** n=1000/10000 | close (both) | same host lo | **none** | **none** | 0 fail | 🟡 |
| M001 | c=100 ab/wrk, 79/65% of nginx | ab burst / wrk 5s | close | same host lo (4 CPUs contended) | none | none | 0 socket err | 🔴 loadgen contention |
| M001 | wrk 5s c=10, 73% of nginx | wrk **5s** | close (wrk's keepalive is disabled) | same host lo | none | none | 0 | 🟡 |
| M002 | c=1 **119%** of nginx (above it) | ab burst n=1000 | close | same host lo | none | none | 0 | 🔴 the doc itself says "noise" |
| M002 | c=10/100 92/87% of nginx | ab burst n=10000 | close | same host lo | none (only dispatch coverage checked) | none | 0 | 🟠 |
| **M003** | **w=4 = nginx w=4 = 159k "dead even"** | **wrk 30s** c=100 | **wrk keepalive vs server close = mismatch** | same host lo | **none** (both 159k = suspected shared ceiling) | **none** | 0 fail | 🟡 the same-condition ratio is fair, the absolute value unproven |
| M003 | E042 "1.76× nginx" | wrk **5s** c=100 | mismatch | same host lo | w=8 over-subscription on 4 CPUs | none | 0 | 🔴 asymmetric, w=8 vs nginx **w=1**; withdrawn later |
| M003 | BPF-select -19% / 21 fail | wrk 30s | mismatch | same host lo | none | none | **21 fail** (race) | 🟡 the difference is fair; the keepalive-locality explanation is unproven |
| M004 | /health p50=0.035ms "17×" | wrk **10s** c=100 | close (the slice cannot keepalive) | same host lo | none | **none** (before E056) | **~0.4% succeeded** (latency covers successes only) | 🟡 only "fast when it succeeds" |
| M004 | ab c=100 "**99.99%** success, usable" | ab burst n=10000 | close | same host lo | none | none | **misread** (withdrawn in E050, really ~35-50%) | 🔴 **summary.md not yet fixed, needs correcting** |
| M004 | E053 sequential 100/100 | curl sequential c=1 | close | same host | N/A | none | 100/100 | 🔵 correctness only |
| M004 | E053 c=10 = 103k RPS | ab burst n=1000 | close | same host lo | none (c=100 **hangs at ~326 req**) | none | c=1/10=0, c=50 timeout | 🟠 a low-concurrency burst peak |
| M004 | E056 peak 84k (after sysctl) | ab burst, several | close | same host lo | **none — the doc names client TCP state as the real cause** | **tw_reuse etc. applied** | 0 (up to the hang point) | 🔴 the author concluded it was loadgen-bound |
| M004 | E057 c=50 = 79k "no regression" | ab burst n=5000 | close | same host lo | none | (same environment as E056) | 0 | 🟠 |
| M004 | E058 loss 20-30%→96-100% | curl sequential c=1 + netem | close | same host lo | N/A | none | 48-50/50 | 🔵 c=1; the response retransmission path never fired |
| E075 | CRuby vs spinel M001/M003 | ab burst + wrk 5/10s | close (both, the same Ruby source) | same host | none (says ~120-130k = the system's limit) | **tw_reuse etc. applied** | 0 | 🟡 the relative ratios (1.27× / even) can be trusted |
| E075 | M004 vs CRuby /health 7-10× | ab burst n=200-2000 | close | same host lo | strace showed the slice makes syscall=0 (CPU not checked) | (E075's sysctl) | 0 | 🟠 the direction is solid; the factor depends on the burst |
| **E186/R2** | **single process 40.5k→95.6k = 2.36×** (before/after the fix) | **wrk 30s** c=100 + a 3s warmup discarded | close (A/B controlled) | same host lo | diagnosed syscall-bound with strace | tw_reuse | **0 fail** | 🟢 **the best methodology in this project** (relative) |
| R2_matched | workers matched, 1.43×/1.07× of nginx (the old 1.76× withdrawn) | wrk 30s c=100 | spinel close / **nginx keepalive (default) = asymmetric, not recorded** | same host lo (4vCPU) | nginx as the control (no direct CPU check) | tw_reuse | **24 fail** on nginx_w4 | 🟡 before/after is solid; the cross-server ratio mixes in the connection asymmetry |
| E180 | sendfile zero-copy | curl + strace (no performance measurement) | close | — | N/A | N/A | correctness 0 fail | ⚪ no performance claim (the mechanism is demonstrated) |
| E188 | kernel-cache c=1 = 3.6× userspace | ab burst n=2000/5000 | close (both) | same host lo, **generic XDP** | partial (convergence at c=10 is lo/SKB serialization) | tw_reuse | 0 | 🟠 a burst peak (the STM32 follow-up demonstrated the sustained collapse) |
| E189 | STM32 native-XDP (what started this audit) | ab/wrk/hey burst+sustained | close | another host (Mac) | **mpstat measured = the board idle** | — | burst 0 / sustained collapse | — burst ~15k / **sustained collapse, not CPU- or bandwidth-bound** |

## Methodology holes found across the board

1. **Server saturation was never checked in any benchmark on lo or in a container.** No case showed "the server is the bottleneck" with CPU% or mpstat (E189's mpstat, the only one, actually **ruled out being compute-bound**). spinel and nginx both landing at 159k in M003 is as consistent with "**a shared ceiling (loadgen / lo / virtualization)**" as with "truly even" — and it was not investigated.
2. **The loadgen almost always shared the host (lo).** The README said it was "**planned** to move it into a separate container in M003", but **that was never done** (E075/E186/E188 kept it on the same host too, as each Edoc says itself). Only E044 counts as "dedicated".
3. **burst vs sustained**: every `ab` run is a `-n <fixed>` burst. Only wrk used a time-based `-d`/`-t` (short at M001/M002 = 5s; M003/E186 = 30s). In E075, c=1 ab RPS decays as n grows (89k→64k) = a burst / warm-state effect.
4. **Connection-model mismatch (a confound)**: wrk uses HTTP/1.1 keepalive by default; the servers use HTTP/1.0 `Connection: close`. E188 states this makes "**the numbers invalid**". It is latent in M003's and R2's cross-server ratios (nginx can keepalive, so in nginx's favour).
5. **Client sysctl applied inconsistently**: E075/E186/E188 apply `tcp_tw_reuse=1` and so on. M001/M002/M003/M004 (the originals) **did not** → under high concurrency with a connection per request they are exposed to TIME_WAIT and port exhaustion.
6. **M004 never tested sustained high concurrency** (everything is a burst or sequential). A c=100 burst **hangs at ~326 req** (E053) / hangs at n=7500+ (E056). E189's "a burst passes but sustained load collapses" **was already visible in M004's data** (the same class of defect).

## What can and cannot be trusted (an honest line)

- 🟢 **Trustworthy**: E186/R2's **before/after 2.36×** (30s sustained + warmup + 0 fail + a control). This alone measures sustained load correctly (the absolute value includes the shared host, but the ratio is solid).
- 🟡 **Only the relative ratio is trustworthy**: M003's "even with nginx", E075's "about even with CRuby / 1.27×", R2's matched workers — each is fair **as a same-condition A/B**. But "the absolute 159k / 120-130k is the server's limit" **cannot be said**.
- 🟠🔴 **Not usable at face value**: M002's "above nginx" (the author says it is noise), M004's RPS figures (all burst or sequential, hangs at c=100), M004's "99.99% success" (**a misreading already withdrawn in E050, really ~35-50%**), E042's "1.76×" (w8 vs w1), E188's absolute RPS (STM32 demonstrated the sustained collapse).

## Corrective actions

- [ ] **`benchmarks/results/M004/summary.md` still shows "99.99% / usable"** (withdrawn in E050 to ~35-50%). **It is stale and needs correcting**.
- [ ] Rebuild the benchmark methodology (a P002 candidate):
  1. **Move the loadgen to another host** (stop sharing lo) — removes the server/client CPU contention
  2. **30-60s duration + record the server's per-core usage and connection state at the same time** — check every time whether the server or the client is the bottleneck
  3. **Label keepalive / Connection: close explicitly** (list them as different things; wrk assumes keepalive, so for a close server use `-H "Connection: close"` or another loadgen)
  4. **Fix the client sysctl (tw_reuse etc.) for every benchmark** so the conditions match
  5. **State absolute values as "conditional peaks", and limit claims to relative ratios**
- [ ] Re-measure two representatives (M001 and M003) with the methodology above, **with the loadgen on another host + sustained + a saturation check**, and relabel the past numbers.

## Re-measurement on another host, round 1: M001 on i.MX95 (2026-06-18) — the lo number is ~40× too high

The audit's corrective action, carried out: M001 (spinel userspace, HTTP/1.0 close, a single blocking accept loop) was started on **i.MX95 (6-core A55, a real 1GbE NIC, glibc 2.42, so the binary runs natively)**, and **the loadgen ran from a Mac (another host, 10-core) while the i.MX95's per-core CPU was measured**. RTT (Mac→i.MX95) = **0.84ms**.

| Setup | RPS | per-req latency | server CPU | state |
|---|---|---|---|---|
| **lo, shared host (E036)** | **~37,285** (c=10 burst) | — | not measured | RTT≈0 hides the serial loop |
| real net c=1 | **958–960** | 1.04ms | idle | **= 1/RTT. latency-bound** |
| real net c=10 | 313 | — | idle | worse with concurrency |
| real net c=50 | 267 | 187ms (mean) | **94% idle** | 50 SYN_SENT on the Mac side, 0 conn on the server |
| real net c=100 (wrk) | 479 | 10.7ms | 4–6% (6 cores) | idle |

**What this showed**:
- **M001's real-network limit is ~1k RPS (1/RTT at c=1), and the server CPU stays idle throughout**. Raising concurrency **does not increase it but makes it worse** (the single blocking accept loop blocks ~RTT per connection in read_line, one connection at a time, so the accept queue fills and the Mac side waits in SYN_SENT). **lo's 37k is an artefact of loopback RTT≈0**, and made real-network throughput look **~40× too high**.
- This is **neither CPU- or bandwidth-bound nor a collapse like kernel-cache's; it is the structural consequence of M001's blocking-serial architecture + the real RTT**. It **confirms by measurement** the audit's "lo's absolute value is not server capacity".
- **Implication**: the lo comparison "M001 = 65–97% of nginx" is likely to fall apart on a real network. nginx is event-driven (epoll, it does not block in read), so it does not become RTT-bound, and on a real NIC **nginx >> M001** is expected (needs a real-hardware comparison of M003 multi-worker + nginx).

### Round 2: M003 multi-worker (w=6) on i.MX95 — it falls apart with multiple workers too

M003 (fork + SO_REUSEPORT, 6 workers, ebpf-mixed `--ebpf-dispatch`) was started on i.MX95 (BPF load+attach succeeds on RT too = it uses no timer or syncookie), with the loadgen on the Mac:

| Setup | RPS | server CPU |
|---|---|---|
| **lo, shared host (E044)** | **~159,011** "even with nginx" | not measured |
| real net c=1 | 877 | idle |
| real net **c=120 (wrk -d20s)** | **197** (read err 126) | **4% on all 6 cores** |
| real net c≥10 (ab) | stall | idle |

- **Even with 6 workers it stays below ~1k on a real network, all cores idle, worse with concurrency**. **Multiple workers do not rescue it**. lo's 159k "even with nginx" is **a loopback artefact** too.

### Meta-conclusion (summing up the re-measurements on both hosts)

| | lo, shared host | real net (Mac→i.MX95) | server CPU |
|---|---|---|---|
| M001 (single) | ~37,285 | ~960 (c=1) | idle |
| M003 (w=6) | ~159,011 | ~877 (c=1) | idle |

1. **lo's absolute value is not the server's real capacity** — RTT≈0 hides the blocking-serial behaviour, **~40–160× too high** against the real network. **Settled by measurement**.
2. **But the real network's ~1k is not "the server's limit" either**: driving close-per-connection (HTTP/1.0) from 1 client (the Mac) tops out at ~1k from **RTT + connection-per-request churn**, with the server idle. That is **a limit on the client / network-path side**, and server capacity is not being measured.
3. ⇒ **As long as these servers are connection-per-request, "server capacity" cannot be measured correctly on lo or on a real network** (lo is too high, the real network is bound by client churn). Measuring true capacity needs **a server with keepalive (persistent connections) + a tuned client**. spinel's HTTP/1.0-close servers do not support keepalive, so **on this axis they cannot be measured correctly in principle**.
### Round 3: nginx on real hardware (2026-06-18) — "even" depends on the connection model; with keepalive nginx is 60×

nginx 1.26.3 was cross-deployed to i.MX95 (the binary + 6 dependent .so files), worker_processes 6, `return 200 "hello"`, the loadgen on the Mac:

| mode (real net, Mac→i.MX95) | **nginx** | **spinel M003 (w=6)** | i.MX95 CPU |
|---|---|---|---|
| **conn-per-request** (both HTTP/1.0 close, fair) | ~762 (c=1), c=50 stall | ~877 (c=1), 197 (c=120) | **idle (4–8%)** |
| **keepalive** (nginx's home ground, wrk -c120 -d20s) | **48,880** (982k req/20s) | **impossible (HTTP/1.0 close, no keepalive support)** | **~90% saturated (all 6 cores)** |

**The settled conclusion (nginx vs spinel, real network)**:
1. **Under the same connection model (conn-per-request), nginx ≈ spinel ≈ ~800 RPS, server idle.** They are even, but only because **both are bound by connection-per-request RTT / client churn**. This does not mean spinel is as fast as nginx; **neither reaches server capacity**. lo's "even with nginx, 159k" is a loopback artefact too.
2. **Allowing keepalive, nginx = 48,880 RPS with the CPU saturated (~90%) = the i.MX95's real server capacity.** spinel **has no keepalive, so it tops out at ~800**. **nginx's lead is ~60×, but what it really is is "the connection model (keepalive)", not raw per-request server speed.**
3. **i.MX95's (6×A55) real keepalive capacity = ~49k RPS (CPU-bound)** is the first real number obtained. spinel **cannot stand on this ground in principle** (no keepalive).

> **Corrective direction**: (a) only **a keepalive-capable variant of the spinel HTTP server** can compete with nginx on the "server capacity" axis (without it, spinel's real ability tops out at ~800 forever). (b) Until then, **state every absolute RPS claim (lo or real net) as "conditional, not capacity"**, and limit relative ratios to the same connection model. Annotate "even with nginx" as **even only for conn-per-request, with both client-bound**.

### Round 4: a keepalive-capable spinel variant (M003ka) — the first fair contest on server capacity (2026-06-18)

Corrective direction (a), implemented: `examples/http_server/M003ka/server.rb` (HTTP/1.1 keepalive, fork+SO_REUSEPORT, pure userspace
`--native-only`). On i.MX95 the worker count was varied, with wrk keepalive from the Mac (-t6 -c120 -d20s):

| Server | worker | RPS | i.MX95 CPU |
|---|---|---|---|
| spinel M003ka | 6  | 17,087 | **~50%** (not saturated) |
| spinel M003ka | 24 | 36,153 | ~90% saturated |
| spinel M003ka | 48 | **38,660** | saturated (topped out) |
| **nginx** | **6** | **48,880** | ~90% saturated |

- **A spinel blocking worker handles only 1 connection per worker** (the keepalive inner loop holds 1 connection). At w=6 it serves only 6 connections at once, CPU 50%. **Only when the workers are oversubscribed to 24–48 (4–8× the 6 cores) does the CPU saturate, reaching ~38k.**
- nginx **multiplexes 120 connections over the same 6 workers** with epoll → CPU saturated at 48.9k.
- **A fair comparison at CPU saturation: nginx 48,880 vs spinel ~38,660 = nginx about 1.27×. spinel is ~79% of nginx.**

**The final conclusion (nginx vs spinel, real network, settled)**:
- conn-per-request: **both even at ~800** (but client/RTT-bound with **the server unused** = a meaningless tie).
- keepalive (the fair server-capacity axis): **spinel ~38k (blocking + many workers, CPU saturated) = ~79% of nginx's 48.9k**.
  spinel is not epoll (a blocking process model), so it **needs 4–8× the workers and peaks ~21% lower**, but it is **competitive at the same order of magnitude** (the first meaningful number, unlike lo's false 159k or conn-per-request's false ~800).
- **An AOT Ruby HTTP server, given keepalive, can deliver ~80% of nginx's throughput on a real network** is the honest result. To go further, **making it event-driven (epoll / non-blocking accept)** is the next axis (removing the blocking process model's ~21% gap and the 4–8× workers).

### Round 5: event-driven (epoll) spinel — above nginx (2026-06-18)

Round 4's next axis, implemented. An epoll FFI was added to `sp_net` (`sp_net_epoll_create/add/del/wait_one`, the ADR-004 patch,
recorded in `SPINEL_EBPF_PATCHES.md`), with `examples/http_server/M003ev/server.rb` (1 worker multiplexes many connections with epoll,
HTTP/1.1 keepalive, pure userspace `--native-only`). **Only 6 workers, the same as nginx**. i.MX95, from the Mac,
wrk -t6 -c120 (same conditions, back-to-back):

| Server (W=6, keepalive) | RPS (run1 / run2) | i.MX95 CPU |
|---|---|---|
| **spinel M003ev (epoll)** | **55,983 / 53,127** | ~90% saturated |
| nginx | 48,880 / 45,821 | ~90% saturated |
| spinel M003ka (blocking, W=6) | 17,087 | ~50% (not saturated) |

- **Made event-driven, spinel reaches ~53–56k at W=6 = ~1.15× nginx (about 15% above it)**, both CPU-saturated. The 4–8× workers blocking needed
  are no longer needed, and the ~21% gap is gone and **reversed**.
- A caveat (fairness): spinel's response has **minimal headers** (only Content-Type/Length), while nginx adds `Server`/`Date` and so on, so
  its response is ~2× larger and its per-request work slightly more. **The ~15% difference on this trivial static response includes "spinel doing
  a little less per request"** (bandwidth is a few % of 1GbE for both, not the bottleneck). With a full-featured server the gap may narrow.

**The final settlement (nginx vs spinel, real network, CPU saturated)**:
| Axis | spinel | nginx | verdict |
|---|---|---|---|
| conn-per-request | ~800 | ~800 | even (both client-bound, meaningless) |
| keepalive + blocking (M003ka) | ~38k (needs W=24–48) | 48.9k | nginx 1.27× |
| **keepalive + event-driven (M003ev, epoll, W=6)** | **~53–56k** | ~46–49k | **spinel ~1.15× (reversed)** |

⇒ **"An HTTP server written in AOT Ruby, made epoll event-driven + keepalive, delivers throughput equal to or above nginx (~15% above on a trivial response)
on a multi-queue NIC on a real network"** — the doubt that began with lo's false 159k finally
arrived at **an honest measurement on the right architecture**, and demonstrated spinel-ebpf's mission (Ruby AOT + a fast HTTP server).
