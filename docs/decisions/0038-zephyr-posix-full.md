# 0038: Full on Zephyr's POSIX layer, and why not in user mode

- Date: 2026-11-12
- Status: Accepted by the owner on 2026-11-12 (the plan: Zephyr v4.4.2's
  POSIX layer on the FRDM-MCXN947, testing both supervisor and user mode,
  and the conclusion that the runtime does not run in user mode).
- Scope: `tools/zephyr-full`, `tests/zephyr-full`.

## Context

Decision [0037](0037-bare-metal-full.md) runs full, the hosted runtime with its
collector, on a Cortex-M with no RTOS. There, everything the runtime needs from
outside that picolibc and the builtins do not define comes from a small
`posix.c` or from nowhere. Counted on the runtime archive built for the
Cortex-M33, 235 external functions: picolibc 119, the builtins 20, `posix.c` 19
and nobody 77. Code that calls one of the 77 links only while no reached code
calls it, so `TCPSocket`, `sleep` and `Marshal` do not link. Decision
[0032](0032-neutron-npu-route.md) runs full under Zephyr, but with the runtime
compiled outside Zephyr against stand-in headers, and without the network.

The question was how much of that gap Zephyr's POSIX layer closes on the same
board, and whether the program can run in a Zephyr user-mode thread, behind the
memory protection unit (MPU), as an application runs behind the kernel on a
general-purpose OS.

## Options

1. **The runtime compiled inside a Zephyr build, against Zephyr's POSIX
   headers**, with Zephyr's sockets, descriptor table, clock and environment.
2. **0032's host:** the runtime compiled outside Zephyr with stand-in headers.
   It sees none of Zephyr's POSIX declarations, so every call Zephyr could
   answer still needs a stand-in.
3. **Zephyr's system calls directly** (`zsock_*`, `k_*`) from a host layer, with
   no POSIX layer. This is what user mode would need, and it means writing the
   environment, descriptors and stdio glue here.

## Decision

Option 1, in supervisor mode. `tools/zephyr-full/spinel-zephyr-full build`
compiles the program and builds `tools/zephyr-full/host` for
`frdm_mcxn947/mcxn947/cpu0`, with the pinned runtime's members compiled as a
static library inside the Zephyr build. No vendor change.

- **What Zephyr supplies.** Counted the same way on the archive built inside
  the Zephyr build, 231 external functions (the headers differ: `htons` is a
  macro there, `FD_SET` and `getnameinfo` are functions): picolibc 84, Zephyr
  75, libgcc 23, the host 7, nobody 42. Zephyr's 75 include the sockets,
  `poll`, `select`, `nanosleep`, `clock_gettime`, `getaddrinfo`, `opendir` and
  `getenv`. The 42 are processes (`fork`, `exec*`, `wait*`, `pipe`, `popen`),
  users and permissions, links, the working directory and a few more.
- **Zephyr's `fdopen` and `fileno` are replaced.** Zephyr's POSIX layer
  defines both over its descriptor table, and its `fdopen` returns the table
  entry itself as a `FILE *`. picolibc's `getline` cannot read that, so a
  socket's `gets` returned `nil` without one `read` (seen with `--trace-io`).
  picolibc's `fopen` calls `fdopen` too. The host links picolibc's own two
  from the SDK's `libc.a`, renamed with `objcopy`, and `--wrap=fdopen` and
  `--wrap=fileno` send every call, picolibc's included, to them.
- **picolibc's floating-point printf is on** (`CONFIG_PICOLIBC_IO_FLOAT`).
  Zephyr's default leaves it off, and `Float#round(n)` for `n >= 15` rounds
  through `snprintf("%.*f")`: `(0.1 * 3).round(15)` printed
  `0.30000000000000004` until it was on.
- **The GC settings are set before the runtime's constructors.** Zephyr runs
  static constructors before `main`, and the runtime reads
  `SPINEL_GC_THRESHOLD_KB` in one. Set in `main`, it came too late: the first
  collection stayed at 256 KB and `gc.rb` ran out of memory before any. A
  constructor of priority 101 in `src/host.c` sets the threshold to 16 KB and
  the slab off, as 0037 does.
- **The host defines the rest:** `_exit` (Zephyr's weak one prints `exit` and
  spins, so `exit 1` printed no status), `posix_memalign` (picolibc's pulls in
  its own malloc next to Zephyr's), `lstat` and the context calls (`ENOSYS`),
  `madvise` (a no-op), and `__freadahead`. The last reads the bytes picolibc
  1.8.10's buffered `FILE` holds, from a prefix of its private
  `struct __file_bufio`; the build stops on another picolibc version
  ([provenance](../provenance.md)).
- **The network starts in the host.** Zephyr does not start DHCP by itself;
  `main` calls `net_dhcpv4_start` and waits up to 30 s for an address before
  the program runs.

### User mode: does not run

`--userspace` builds the same program with `CONFIG_USERSPACE` and runs it in a
user-mode thread. The thread's memory domain holds a partition with the
runtime's and the host's globals, picolibc's partition and malloc's arena.
Every program faulted at its first `getenv`: Zephyr's `getenv` takes
`environ_lock`, a semaphore in kernel memory, and the MPU stops the access.

This is how Zephyr's POSIX layer is built, not a fault of this host. In
Zephyr v4.4.2, `lib/posix` and `lib/os/zvfs` place no state in memory a user
thread may reach, and of the descriptor table's calls only `zvfs_poll` and
`zvfs_select` are system calls; `read`, `write`, `open` and `getenv` are plain
functions. Zephyr's system calls are the kernel API (95 in `kernel.h`), the
sockets (22 `zsock_*`) and a few more. Zephyr documents user mode as an option
for sandboxing untrusted parts, with the kernel and supervisor code trusted. It
documents the POSIX layer as an API subset for porting, with the application
seen as one process ([User Mode Overview](https://docs.zephyrproject.org/latest/kernel/usermode/overview.html),
[POSIX Overview](https://docs.zephyrproject.org/latest/services/portability/posix/overview/index.html)).
Running the runtime in user mode would take option 3. The conclusion, accepted
by the owner, is that this route runs in supervisor mode only.
`host/userspace.conf` and the `CONFIG_USERSPACE` path in `src/host.c` stay so
that the result can be reproduced.

## Limits

- One board, `frdm_mcxn947/mcxn947/cpu0`: Zephyr in the secure state, with
  the non-secure side unused.
- Supervisor mode only (above).
- No file system is mounted (`CONFIG_FILE_SYSTEM` is on with no backend), so
  file calls link but fail at run time. Signals (`kill`, `sigaction`), `mmap`
  and `mprotect` link to Zephyr functions that fail on this core.
- Integer is 32 bits, as in 0037 ([0019](0019-target-integer-width.md)).
- One program per image. The board runs are by hand: `tests/zephyr-full`
  checks the builds, and `check-log.rb` compares a capture with the
  expectation.
- Measured with seven programs only.

## Evidence

`sh tests/zephyr-full/run.sh` on Debian 13, 2026-11-12: 44 passed, 0 failed,
1 m 35 s. Every program builds; no image links Zephyr's `fdopen` or `fileno`,
and `tcp.rb`'s socket stream comes from picolibc's; the host's constructor runs
first; picolibc's floating-point printf is on; no image names the checkout or
the work directory. `basics.rb` builds with `--userspace`, its globals in the
partition. `check-log.rb` accepts a capture of the expected output and rejects
three planted changes, and the controls (a planted `fdopen` in the symbol
list, a map without the host's constructor, a planted path) fail as they
should.

### The FRDM-MCXN947 board, 2026-11-12

Built with `tools/zephyr-full/spinel-zephyr-full` at 0b2b1eb7 plus this
change, on Debian 13, and run once by hand. Each image was written at
0x10000000 with LinkServer 26.3.123
(`LinkServer flash MCXN947:FRDM-MCXN947 load --addr 0x10000000 <image>`, which
resets the core after writing), its sha256 checked after the copy, and the
console captured from before the load. Each capture was compared with
`check-log.rb`. The board had DHCP on its Ethernet port, and
`echo-peer.rb` was listening at the address given with `--peer`.

| Program | Flash / RAM (Zephyr's report) | Console |
|---|---|---|
| `basics.rb` | 296,680 / 117,700 B | its `.out` exactly, `GC 0`, `EXIT 0` |
| `float.rb` | 255,544 / 106,732 B | its `.out` exactly, `GC 0`, `EXIT 0` |
| `gc.rb` | 264,016 / 143,988 B | its `.out` exactly, `GC 43`, `EXIT 0` |
| `oom.rb`, `--heap 65536` | 242,300 / 182,764 B | `unhandled exception: out of memory`, `GC 3`, `EXIT 1` |
| `sleep.rb` | 161,988 / 116,876 B | `true`, `true`, `GC 0`, `EXIT 0` |
| `tcp.rb` | 259,288 / 127,116 B | `hello from spinel`, `closed`, `GC 0`, `EXIT 0`; the peer logged the line |
| `marshal.rb` | 288,736 / 143,500 B | `[1, "two", :three, {"k" => 4.5}, nil, true]`, `true`, `GC 0`, `EXIT 0` |
| `basics.rb`, `--userspace` | | `ZFULL MODE user 0 3`, then an MPU fault: data access at `environ_lock` from `z_getenv`; no output, no exit line in 120 s |

`gc.rb` collected the same 43 times as on the bare-metal lane. The same
programs, built from the scratch prototype this tool was made from, gave the
same results the run before, where all seven user-mode builds faulted at the
same place.
