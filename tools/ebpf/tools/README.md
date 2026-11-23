# spinel-ebpf turnkey tools (E111)

A set of observability tools that **work as they are**, the counterpart of bcc's `tools/`. Each tool is a
single Ruby (spinel-ebpf subset) file and uses the DSL idioms established in the Edocs so far
(kprobe / raw_tracepoint / latency hist / ivar counter / hist dump FFI).

## Build & run

```bash
bin/spinel-ebpf compile tools/<tool>.rb --build -o build/<tool>
sudo ./build/<tool>/<tool>
```

`<tool>` runs in the debian:trixie build container on a kernel with BTF enabled
(see "Build / environment" in spinel-ebpf's CLAUDE.md).

## Included tools

| Tool | bcc counterpart | Mechanism | Output |
|---|---|---|---|
| `funclatency.rb` | funclatency | kprobe `latency_start` + kretprobe `hist_observe(latency_end)` | **prints its own log2 histogram after 5s of sampling** (`spnl_dump_log2_hist` FFI) |
| `syscount.rb` | syscount | raw_tracepoint `sys_enter` + counter | `bpftool map dump name syscount_top_c` |
| `funccount.rb` | funccount | kprobe + counter (edit the function name for any function) | `bpftool map dump name funccount_top_c` |
| `vfsstat.rb` | vfsstat | kprobe `vfs_read`/`vfs_write`/`vfs_open` + 3 counters | `bpftool map dump name vfsstat_top_{re,wr,op}` |
| `opensnoop.rb` | opensnoop | tracepoint `sys_enter_openat` + `spnl_emit_str` + streaming | **streams openat filenames in real time** (`spnl_stream` FFI, E112) |
| `inject.rb` | inject | `fmod_ret/security_file_open` + comm scope | injects -EPERM into the victim process's open() (E113), count in `@injected` |
| `sslsniff.rb` | sslsniff | uprobe `SSL_write` + `spnl_emit_str` + streaming | **streams TLS plaintext in real time** (E114), `SPNL_UPROBE_BINARY=libssl.so.3` |
| `trace.rb` | trace | tracepoint + `if` predicate + `spnl_emit_str` + streaming | **predicate-filtered event trace** (E115), in-kernel filter on comm and so on |
| `argdist.rb` | argdist | tracepoint arg + `path_counter_inc` (-C) / `hist_observe` (-H) | **frequency table / log2 distribution per expression value** (E116), `bpftool map dump bpf_path_counts` |
| `memleak.rb` | memleak | kmem/kmalloc+kfree tracepoint + `leak_record`/`leak_forget` + `spnl_dump_leaks` | **aggregates and symbolizes unfreed kmalloc per stack** (E117), kernel mode |
| `deadlock.rb` | deadlock | uprobe pthread_mutex_lock/unlock + `task_swap` + `lock_edge` + `spnl_dump_deadlocks` | **detects lock-order inversion (AB-BA)** (E118), comm scope |
| `execsnoop.rb` | execsnoop | tracepoint sys_enter_execve + `emit_argv` + streaming | **streams execve with every argv element** (E119) |
| `runqlat.rb` | runqlat | sched_wakeup/sched_switch + `lat_start`/`lat_end` + `hist_observe` | **log2 histogram of run-queue latency** (E120) |
| `biolatency.rb` | biolatency | kprobe blk_mq_start/end_request + `lat_start`/`lat_end` (request ptr key) | **log2 histogram of block I/O latency** (E121) |
| `tcplife.rb` | tcplife | sock/inet_sock_set_state + `lat_start`/`lat_end` (sock key) + `spnl_emit3` + streaming | **streams TCP connection lifetimes** (E122, MVP: ports+duration) |
| `tcpconnect.rb` | tcpconnect | sock/inet_sock_set_state (CLOSE→SYN_SENT) + ipv4 field + `spnl_emit_pair` | **streams outbound connections by daddr+dport** (E123) |
| `tcpaccept.rb` | tcpaccept | sock/inet_sock_set_state (SYN_RECV→ESTABLISHED) + ipv4 field | **streams inbound connections by lport+raddr** (E123) |
| `exitsnoop.rb` | exitsnoop | sched_process_exit + `spnl_emit` + `emit_comm` | **streams process exits (pid+comm)** (E124) |
| `killsnoop.rb` | killsnoop | sys_enter_kill + `spnl_emit_pair` | **streams kill(2) signal sends (target pid+signal)** (E124) |
| `cpudist.rb` | cpudist | sched_switch + `lat_start`/`lat_end` (pid key) + `hist_observe` | **log2 histogram of the on-CPU time distribution** (E125) |
| `hardirqs.rb` | hardirqs | irq_handler_entry/exit + `cpu_id` key + `hist_observe` | **histogram of hard IRQ handler time** (E125) |
| `softirqs.rb` | softirqs | softirq_entry/exit + `cpu_id` key + `hist_observe` | **histogram of soft IRQ handler time** (E125) |
| `statsnoop.rb` | statsnoop | sys_enter_newfstatat/statx + `spnl_emit_str` | **streams stat(2) paths** (E126) |
| `syncsnoop.rb` | syncsnoop | sys_enter_sync/fsync/fdatasync + `spnl_emit` | **streams the pid calling sync(2)** (E126) |
| `tcpstates.rb` | tcpstates | sock/inet_sock_set_state (every transition) + `spnl_emit4` | **streams TCP state transitions** (E127) |
| `capable.rb` | capable | kprobe cap_capable + `spnl_emit` + `emit_comm` | **streams capability checks (cap+comm)** (E128) |
| `gethostlatency.rb` | gethostlatency | uprobe/uretprobe getaddrinfo + `latency_start`/`latency_end` + `hist_observe` | **log2 histogram of name resolution latency** (E129), `SPNL_UPROBE_BINARY=libc.so.6` |
| `biosnoop.rb` | biosnoop | blk_mq_start/end_request + `lat_start`/`lat_end` + `kfield` + `spnl_emit3` | **(sector,bytes,latency) per block I/O** (E130) |
| `runqslower.rb` | runqslower | sched_wakeup/switch + keyed-latency + threshold | **streams run-queue waits > 1ms as (pid,latency)** (E131) |
| `fileslower.rb` | fileslower | kprobe/kretprobe vfs_read + tid-latency + threshold | **streams vfs_read > 1ms** (E131) |
| `tcpretrans.rb` | tcpretrans | kprobe tcp_retransmit_skb + `kfield` (dotted embedded path) | **streams TCP retransmissions by (daddr,dport)** (E132, load/attach+kfield verified; provoking a real retransmission needs a really lossy link) |
| `mountsnoop.rb` | mountsnoop | sys_enter_mount/umount + `spnl_emit_str` | **streams the target paths of mount/umount** (E133) |
| `cachestat.rb` | cachestat | kprobe folio_mark_accessed/filemap_add_folio/mark_buffer_dirty + `path_counter_inc` | **page cache hit/miss statistics** (E134), `bpftool map dump bpf_path_counts` |
| `filelife.rb` | filelife | security_inode_create→vfs_unlink + keyed-latency (dentry) | **streams the create→unlink lifetime of short-lived files** (E135) |
| `slabratetop.rb` | slabratetop | kmem/kmem_cache_alloc + `hist_observe(bytes_alloc)` | **slab allocation size distribution + rate** (E136) |
| `setuids.rb` | setuids | sys_enter_setuid/setresuid + `spnl_emit`/`spnl_emit3` | **streams the target uid of setuid/setresuid** (E137) |

### Measured (spinel-004, E111)

- `funclatency`: shows the latency of `do_sys_openat2` as a log2 histogram (bcc ASCII art).
- `syscount`: counted **31,758 syscalls** in 1.3s.
- `vfsstat`: **opens=2215 / reads=76 / writes=195** with `find /usr` and the like.
- `opensnoop`: shows openat filenames live in arrival order (the E112 streaming base).
- `inject`: injects EPERM into open() only for comm=injtest, `@injected=4` confirmed on the real machine (spinel-003).
- `sslsniff`: captures the TLS plaintext `GET /sniffme` / `GET /curltest` of openssl s_client + curl before encryption (E114).
- `trace`: streams 33 lines for only the opens of comm=trycat; `cat`'s opens are excluded by the predicate (E115).
- `argdist`: aggregates the write size distribution as `{64:50, 4096:20}`, matching the 2 dd runs exactly (E116).
- `memleak`: captures and symbolizes 30 unfreed kmallocs (9096 bytes / 18 stacks) from the maple-tree RCU of mmap/munmap (E117).
- `deadlock`: detects the lock-order inversion of the AB-BA demo exactly, with 2 edges / 1 inversion (E118).
- `execsnoop`: captures the filename + every argv element of `echo ALPHA BETA GAMMA DELTA`, breaking at the terminator (E119).
- `runqlat`: measures run-queue latency; under light load, a peak at 2-4µs + a long tail of ~2-4ms (E120).
- `biolatency`: measures block I/O latency with dd to vdb; a peak at 16-32µs + a ~ms tail (E121).
- `tcplife`: measures TCP connections held for 300/600/900ms as 310/610/910ms, matching (E122).
- `tcpconnect`/`tcpaccept`: capture a connection to 127.0.0.1:8123 as daddr=16777343/dport=8123 (E123).
- `exitsnoop`/`killsnoop`: capture exiting process names and kill signals (pid,15)/(pid,2) (E124).
- `cpudist`/`hardirqs`/`softirqs`: measure a bimodal on-CPU distribution / hard IRQ 8-32µs / soft IRQ 8-16µs (E125).
- `statsnoop`/`syncsnoop`: capture stat paths under /etc/* and the pids calling sync/fsync (E126).
- `tcpstates`: captures the whole lifecycle of the TCP state machine (client+server) for 1 connection (E127).
- `capable`: observes the CAP_SYS_NICE(23) check of `nice -n -5` by cap number + comm (E128).
- `gethostlatency`: tells apart curl's getaddrinfo at localhost ~0.5ms / failing DNS at tens to hundreds of ms (E129).
- `biosnoop`: captures dd's 8 block I/Os per I/O with sector/65536B/latency (E130).
- `runqslower`/`fileslower`: capture run-queue waits of 1.2-14ms and vfs_read of 603/412ms above the threshold (E131).


## Extending

By combining the attach kinds the DSL covers (kprobe/uprobe/USDT/tracepoint/fentry/raw_tp/
perf_event/LSM/fmod_ret/cgroup/iter) and the builtins (hist/stack/latency/task_storage/
emit/...), bcc's other tools (opensnoop / execsnoop / biolatency /
runqlat / tcplife ...) can be written the same way. Changing just the 2 method names in
`funclatency.rb` to another kprobe/kretprobe pair turns it into a latency tool for any function.
