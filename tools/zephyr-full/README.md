# tools/zephyr-full: full on Zephyr's POSIX layer

A Spinel program with the hosted runtime and its collector, built into a
Zephyr v4.4.2 application for the FRDM-MCXN947 board (`frdm_mcxn947/mcxn947/cpu0`),
on Zephyr's POSIX layer, its IPv4 network stack and picolibc
([decision 0038](../../docs/decisions/0038-zephyr-posix-full.md)). Where
`tools/bare-full` (in spinel-modular, the submodule `vendor/spinel-modular`) supplies the few POSIX calls the
runtime makes itself, here Zephyr supplies sockets, `poll`, `nanosleep`,
`clock_gettime`, the descriptor table and the environment, so programs that use
`TCPSocket`, `sleep` or `Marshal` link and run.

The program runs in supervisor mode. `--userspace` builds the same program in a
user-mode thread; that build faults in Zephyr's POSIX layer (decision 0038).

## What it needs

| What | Where |
|---|---|
| `ZEPHYR_BASE` | the pinned Zephyr v4.4.2 tree ([installation record](../../docs/toolchains/zephyr-v4.4.2/INSTALLATION-RECORD.md)) |
| `ZEPHYR_SDK_INSTALL_DIR` | the Zephyr SDK 1.0.1 |
| `west` | on `PATH`, the installation's venv first |
| `SPINEL_DIR` | optional; the Spinel checkout, by default `vendor/spinel`, which must be built |

The driver checks the build log for that tree and that SDK, because
`ZEPHYR_SDK_INSTALL_DIR` alone does not select the SDK, and passes
`-DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON`.

## Use

```sh
ROOT=$HOME/toolchains/zephyr-v4.4.2
export PATH="$ROOT/.venv/bin:$PATH" ZEPHYR_BASE="$ROOT/workspace/zephyr" \
  ZEPHYR_SDK_INSTALL_DIR="$HOME/zephyr-sdk-1.0.1"
tools/zephyr-full/spinel-zephyr-full build app.rb out/
sh tests/zephyr-full/run.sh
```

`out/zephyr.bin` is the flash image, to be written at `0x10000000`; `out/build`
is the Zephyr build (its `zephyr/zephyr.map` and `.config`). Options:

| Option | Effect |
|---|---|
| `--heap BYTES` | the malloc arena; by default the RAM nothing else uses |
| `--peer HOST:PORT` | set as `ZFULL_PEER` in the program's environment |
| `--userspace` | run the program in a user-mode thread (`host/userspace.conf`) |
| `--trace-io` | print each `read`, `fcntl`, `send`, `recv`, `connect` and `poll` with its result and `errno` |

A build takes about 11 s on Debian 13. `tests/zephyr-full/run.sh` builds every
program and checks the images; it does not need the board.

## Running on the board

There is no board lane: a board run is by hand. On the host with the board's
MCU-Link, start reading its console at 115200 baud, then write the image:

```sh
stty -F /dev/ttyACM0 115200 raw -echo -hupcl; cat /dev/ttyACM0 > basics.log &
LinkServer flash MCXN947:FRDM-MCXN947 load --addr 0x10000000 zephyr.bin
```

LinkServer resets the core after writing; stop reading after the
`ZFULL<TAB>EXIT` line. The board needs Ethernet with a DHCP
server; `tcp.rb` also needs `ruby tests/zephyr-full/echo-peer.rb` listening at
the address given with `--peer`. Then compare the capture with the program's
hand-written expectation:

```sh
ruby tests/zephyr-full/check-log.rb basics.log vendor/spinel-modular/tests/bare-full/programs/basics.out
ruby tests/zephyr-full/check-log.rb oom.log tests/zephyr-full/programs/oom.out 1
```

`basics`, `float`, `gc` and `oom` (built with `--heap 65536`) are
`vendor/spinel-modular/tests/bare-full/programs`; `sleep`, `tcp` and `marshal` are
`tests/zephyr-full/programs`.

## The console

`src/host.c` prints, each field separated by a tab:

| Line | When |
|---|---|
| `ZFULL BEGIN` | at the start of `main` |
| `ZFULL NET up` or `none` | after DHCP, or after 30 s without it |
| `ZFULL MODE supervisor`, or `user <rc> <partitions>` | just before the program starts |
| the program's output | |
| `ZFULL GC <n>`, `ZFULL EXIT <status>` | when the program returns or calls `exit` |

## What the host does

- **Builds the runtime inside Zephyr's build.** The runtime's members (the
  Spinel Makefile's `RT_MEMBERS` and `RE_SRC`) and the program's `app.c` are a
  static library compiled with Zephyr's flags and headers. `host/force.h`
  declares what Zephyr's POSIX headers leave out; decision 0032's header
  stand-ins (`tools/npu/host/shim`) come after Zephyr's, read from there.
- **Replaces Zephyr's `fdopen` and `fileno`.** Zephyr's `fdopen` returns its
  descriptor-table entry as a `FILE *`, which picolibc's stdio cannot read: a
  socket's `gets` returned `nil`. The build takes picolibc's own two from the
  SDK's `libc.a`, renames them, and `--wrap` sends every call to them.
- **Sets the GC settings before the runtime's constructors.** Zephyr runs
  static constructors before `main`, and the runtime reads
  `SPINEL_GC_THRESHOLD_KB` in one; a constructor of priority 101 sets it to 16
  and the slab off, as on the bare-metal lane.
- **Defines what nobody else does:** `_exit` (Zephyr's prints only `exit`),
  `posix_memalign`, `lstat` and the context calls (`ENOSYS`), `madvise` (a
  no-op), and `__freadahead`, which reads picolibc 1.8.10's buffered `FILE`
  (the build stops on another picolibc version).

## Limits

- One board, `frdm_mcxn947/mcxn947/cpu0`: Zephyr in the secure state, the
  non-secure side unused.
- Supervisor mode only; the user-mode build faults (decision 0038).
- No file system is mounted: file calls link but fail at run time.
- Integer is 32 bits on this target, as on the bare-metal lane
  ([0019](../../docs/decisions/0019-target-integer-width.md)).
- Measured with the seven programs above only.
