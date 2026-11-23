# R2 matched benchmark — nginx vs spinel-ebpf, an honest comparison with matched worker counts + the effect of the fix

For deck revision R2 (`presentation/REVISION_R2.md` #10). The old claim "1.76 times nginx with a single worker" was
the asymmetric comparison **spinel w=8 vs nginx w=1**. This measures again with matched workers, and also records
**before and after fixing the bottleneck found by profiling** (find → fix → win, E186).

## Environment / method

- container: `kverify512` (Apple container 1.0.0, Linux 7.0.12-spinel-005, **4 vCPU**).
- server: `examples/http_server/M003/server.rb` (`--build --ebpf-dispatch`, `SPINEL_HTTP_WORKERS=N`)
  / nginx uses `benchmarks/targets/nginx_hello*.conf` (w=1 / w=4 + reuseport).
- load: `wrk -t<nproc> -c100 -d30s --latency http://127.0.0.1:<port>/` inside the same container (`run_wrk.sh`). 3s warmup discarded.
- `wrk.csv` = before the fix (1-byte recv) / `wrk_fixed.csv` = after the fix (buffered read_line). nginx is the control (constant before and after).

## Results (wrk c=100, 30s)

| Configuration | nginx RPS | spinel before fix | spinel **after fix** | after-fix spinel/nginx |
|---|---|---|---|---|
| **w=1** | 60,293 to 61,379 | 38,543 (**0.63×**) | **86,383** (p50 1.00ms) | **1.43×** |
| **w=4** | 69,500 to 73,964 | 59,365 (**0.80×**) | **74,618** (p50 1.01ms) | **1.07×** |

## The bottleneck and the fix (E186)

- **Profile (strace)**: `sp_net_read_line` read one request with **27 calls of `recv(fd,&c,1,0)`** (1 byte/syscall,
  the request line + each header). nginx does 1 recvfrom/req. Total syscalls were spinel ~30/req vs nginx ~10/req.
- **It looks weak in the on-CPU profiler (eBPF)**: each recv is cheap; the cost is **the mode switch of syscall entry and exit × 27**
  (on the kernel side) and is not stacked on read_line in the user stack. `sp_net_read_line`'s on-CPU samples only move from 9→4.
  **A syscall-count bottleneck looks too small in an on-CPU flame graph** — strace is the right lens.
  (flame graph SVGs are `../R2_profile/{before,after}_flame.svg`)
- **The fix (`third_party/spinel/lib/sp_net.c`)**: buffer fill — read 64KB with one `recv()` and cut lines out of
  the buffer (equivalent to CRuby `IO#gets` / nginx). Reset per connection in `sp_net_close`; the HTTP→WS transition is
  safe because `sp_ws_read_n` drains `sp_net_read_line_buffered_remaining`.
- **Effect (measured with strace)**: recvfrom **27→1/req**, total syscalls **~30→~4.8/req**. Single-process RPS went
  40,527 → 95,578 (**2.36×**, `../R2_profile/fix_rps.csv`).

## Conclusion (honestly)

- **At first, with matched workers, spinel lost** (0.63× at w=1). This is what E075's "cases where it loses in pure userspace"
  really were = the syscall cost of the 1-byte recv.
- **Once profiling pinpointed it and buffering removed it, spinel beats nginx even with matched workers**
  (w=1 1.43× / w=4 1.07×). "Measure, fix, measure again" shows directly in the numbers.
- Absolute values include virtualization because the loadgen shares the container (the dedicated E044 measurement had w=4 ≈ even at 159k). **The ratios are fair** and the conclusion stands.
