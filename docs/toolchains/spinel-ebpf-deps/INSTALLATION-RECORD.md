# spinel-ebpf dependencies and privileges -- installation record

What `tools/ebpf` needs on a host, beyond `docs/building.md`, and every
privileged command run to port and check it. Recorded on Debian 13 (x86_64,
host kernel 7.1.8 with `/sys/kernel/btf/vmlinux`), 2026-09-23.

## Third-party sources, user-local

| | pin | where | used for |
|---|---|---|---|
| nanopb | `nanopb-0.4.9.1`, commit `cad3c18ef15a663e30e3e43e3a752b66378adec1` (zlib license) | `~/toolchains/nanopb-0.4.9.1`, named by `NANOPB_DIR` | the OTLP protobuf encoder the runtime compiles in |
| mbedTLS | `v3.6.6`, commit `0bebf8b8c7f07abe3571ded48a11aa907a1ffb20` (Apache-2.0) | `~/toolchains/mbedtls-3.6.6` (2026-10-24), named by `MBEDTLS_DIR` | only programs that send OTLP over `https://` or `grpcs://` |
| opentelemetry-proto | `v1.10.0`, commit `ca839c51f706f5d53bfb46f06c3e90c3af3a52c6` (Apache-2.0) | `~/toolchains/opentelemetry-proto-ca839c51` (2026-10-24), named by `OTEL_PROTO_DIR` | the `.proto` files protoc decodes the OTLP harnesses' captures with |
| protoc | `31.1`, the protobuf project's prebuilt `protoc-31.1-linux-x86_64.zip` (BSD-3-Clause) | `~/toolchains/protoc-31.1` (2026-10-24), named by `PROTOC` (`bin/protoc`) | the OTLP harnesses' decode of a protobuf capture |

These are the commits of spinel-ebpf's submodules at `23fa4b0`.

```sh
cd ~/toolchains
git clone --depth 1 --branch nanopb-0.4.9.1 https://github.com/nanopb/nanopb nanopb-0.4.9.1
git -C nanopb-0.4.9.1 rev-parse HEAD      # cad3c18e...
```

Added on 2026-10-24 for the OTLP harnesses (`tools/ebpf/README.md`), without
sudo or a package manager. mbedTLS comes from the release tarball, which holds
the generated sources a git checkout lacks (generating them needs Python);
its digest is the one GitHub publishes for the asset. GitHub publishes no
digest for the protoc zip; the one below was computed after the download.

```sh
cd ~/toolchains
git clone https://github.com/open-telemetry/opentelemetry-proto opentelemetry-proto-ca839c51
git -C opentelemetry-proto-ca839c51 checkout ca839c51f706f5d53bfb46f06c3e90c3af3a52c6   # v1.10.0
mkdir protoc-31.1 && cd protoc-31.1
curl -fsSLO https://github.com/protocolbuffers/protobuf/releases/download/v31.1/protoc-31.1-linux-x86_64.zip
sha256sum protoc-31.1-linux-x86_64.zip   # 96553041f1a91ea0efee963cb16f462f5985b4d65365f3907414c360044d8065
unzip protoc-31.1-linux-x86_64.zip       # bin/protoc --version: libprotoc 31.1
cd ~/toolchains
curl -fsSLO https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.6/mbedtls-3.6.6.tar.bz2
sha256sum mbedtls-3.6.6.tar.bz2          # 8fb65fae8dcae5840f793c0a334860a411f884cc537ea290ce1c52bb64ca007a (as published)
tar xjf mbedtls-3.6.6.tar.bz2            # mbedtls-3.6.6/; the tag v3.6.6 is commit 0bebf8b8
```

Already on the host and used as found: clang 19.1.7 (Debian) for `-target bpf`
and the host code, libbpf 1.5.0 and libelf (`pkg-config`), zlib, and
`/usr/local/bin/bpftool` v7.8.0.

## Privileges

The owner approved administrator rights on this host for eBPF on 2026-09-23,
to be used as little as possible.

- **What is granted.** File capabilities `cap_bpf,cap_net_admin,cap_perfmon`
  on each program under test, with `sudo setcap`. The program then runs as
  the user. No program was run as root. No package was installed or removed,
  no service changed, no sysctl written.
- **Where.** File capabilities are ignored on a `nosuid` mount, and `/tmp` is
  one here. The binaries go to `~/toolchains/spinel-ebpf-run`, a directory the
  user owns on `/` (ext4, no `nosuid`); `tests/ebpf/live.sh` refuses a
  `nosuid` directory. After the runs, all eight capability-bearing binaries
  there were deleted.
- **Reading maps.** A map dump needs the same capabilities, so the checks run
  `sudo bpftool` (read-only: `map show`, `map dump`, `prog show`,
  `net show dev lo`).
- **XDP.** The programs attach to `lo` for a few seconds and detach on exit.
  Every check confirms afterwards that `lo` has no XDP program.

### Every privileged command

`tests/ebpf/live.sh` logs its privileged commands and prints them. Its run on
2026-09-23 made these:

```
sudo setcap cap_bpf,cap_net_admin,cap_perfmon+ep ~/toolchains/spinel-ebpf-run/{m002,m003,tcp_slice,ruby_slice,enforcer}
sudo bpftool map dump name bpf_path_counts
sudo bpftool -j prog show
sudo bpftool -j map show
sudo bpftool map dump id <the run's SOCKARRAY>
sudo bpftool map dump name bpf_hist_keyed
sudo bpftool net show dev lo            (3 times)
```

Before the script existed, while porting, these were run by hand, all of the
same kinds:

```
sudo -n true                                        (whether sudo asks for a password)
sudo setcap cap_bpf,cap_net_admin,cap_perfmon+ep <scratch>/m002/server     (ignored: nosuid)
sudo setcap cap_bpf,cap_net_admin,cap_perfmon+ep ~/toolchains/spinel-ebpf-run/{m002_server,m003_server,tcp_slice,ruby_slice,access_enforcer}
sudo setcap ... ~/toolchains/spinel-ebpf-run/access_enforcer               (once more; the first failed, no file yet)
sudo bpftool map dump name bpf_path_counts / bpf_worker_sock / bpf_worker_socks / bpf_hist_keyed
sudo bpftool map dump id <id>
sudo bpftool map show [name bpf_worker_sock]
sudo bpftool prog show [type sk_reuseport]          (the type form is refused by bpftool)
sudo bpftool net show dev lo
sudo ss -ltnp sport = :8080
```

Two manual runs of the M003 server were left running after a check, holding
:8080, and were stopped by pid. `tests/ebpf/live.sh` starts each server in its
own process group and stops the group.

## xdp-counter (examples/ebpf-go), 2026-09-23

`tests/ebpf-go/live.sh` grants `cap_bpf,cap_net_admin` (no `cap_perfmon`:
the program needs no more) to the one binary, and deletes it afterwards. Its
privileged commands, and the ones run by hand before the script:

```
sudo setcap cap_bpf,cap_net_admin+ep ~/toolchains/spinel-ebpf-run/xdp-counter
sudo bpftool prog show            (whether count_packets is left)
sudo bpftool net show dev lo      (whether an XDP program is left on lo)
```

spinel-llvm's own kernel scripts (`tools/ebpf/go/testdata/kernel/*.sh`) ran
as root inside a network namespace. They are not run here.

## The OTLP harnesses' probes, 2026-10-24

`tools/ebpf/tests/runtime/run_otlp_kernel_e2e.sh` and `run_gpu_host_probe.sh`,
given `EBPF_CAP_DIR=~/toolchains/spinel-ebpf-run`, copy their probe there,
grant it capabilities and delete it at the end; each prints its privileged
command on a `priv:` line. `run_otlp_kernel_e2e.sh` grants
`cap_bpf,cap_net_admin,cap_perfmon`. `run_gpu_host_probe.sh` granted the same
three until 2026-10-24, and since then grants
`cap_bpf,cap_net_admin,cap_perfmon,cap_sys_admin` (below). No program ran as
root and `sudo -n` was not used. Every privileged command, in order (`<pid>`
is the harness's process id, part of the copy's name):

```
sudo setcap cap_bpf,cap_net_admin,cap_perfmon+ep ~/toolchains/spinel-ebpf-run/gpu_host_probe.<pid>    (first run)
sudo setcap cap_bpf,cap_net_admin,cap_perfmon+ep ~/toolchains/spinel-ebpf-run/otlp_e2e_probe.<pid>    (once its prerequisites were set)
sudo setcap cap_bpf,cap_net_admin,cap_perfmon+ep ~/toolchains/spinel-ebpf-run/uprobe_diag             (the diagnosis below)
sudo setcap cap_bpf,cap_net_admin,cap_perfmon+ep ~/toolchains/spinel-ebpf-run/otlp_e2e_probe.<pid>    (final run)
sudo setcap cap_bpf,cap_net_admin,cap_perfmon+ep ~/toolchains/spinel-ebpf-run/gpu_host_probe.<pid>    (final run)
```

Each copy was deleted after its run; the directory was left empty.

**The GPU host probe's uprobe is refused with these three capabilities.** The
probe loads its BPF object, then libbpf 1.5.0 fails to attach the uprobe:
`failed to create uprobe '<target>:0x11e0' perf event: Permission denied`.
libbpf takes the perf PMU path, not the legacy tracefs one:
`/sys/bus/event_source/devices/uprobe/type` (9) is readable by the user,
while `/sys/kernel/tracing` is root's only (0700). A scratch program that
makes the same `perf_event_open` (uprobe PMU; pid -1 on cpu 0, and its own
pid on any cpu) on the same target, run once with
`cap_net_admin,cap_perfmon,cap_bpf=ep` in effect and the target readable,
got EACCES both ways. So CAP_PERFMON alone does not admit a uprobe here. What
refuses it (another capability, or a security module: this kernel, 7.1.8,
runs lockdown, landlock, yama, apparmor, tomoyo, bpf, ipe, ima and evm, and
its log is not readable by the user) was not determined, and no further
capability was granted. spinel-ebpf ran this harness in its build container
(E471), which its records start with `--cap-add ALL` (E325).

**With `cap_sys_admin` added, it passes.** The owner approved one run to
find the cause (2026-10-24). A scratch copy of `run_gpu_host_probe.sh`,
differing only in its repository root and in the capability list, was run
once with `EBPF_CAP_DIR=~/toolchains/spinel-ebpf-run`. Its one privileged
command:

```
sudo setcap cap_bpf,cap_net_admin,cap_perfmon,cap_sys_admin+ep ~/toolchains/spinel-ebpf-run/gpu_host_probe.<pid>
```

The run passed in 10 s: three API series decoded with histogram count 50
each, and the negative control (`/bin/true`, no symbols) refused with
FATAL and pushed nothing. The copy was deleted and the directory left
empty. So the uprobe needs `CAP_SYS_ADMIN` beyond the three on this host.
Which kernel check asks for it was not observed. A guess: the uprobe PMU's
event setup, or a security module's `perf_event_open` hook, tests
`CAP_SYS_ADMIN` rather than `CAP_PERFMON`.

**The harness grants `cap_sys_admin` (2026-10-24).** The owner approved adding
it to `run_gpu_host_probe.sh`'s `EBPF_CAP_DIR` path only;
`run_otlp_kernel_e2e.sh` keeps the three. The tracked harness, so changed,
was run once with `EBPF_CAP_DIR=~/toolchains/spinel-ebpf-run`. Its one
privileged command:

```
sudo setcap cap_bpf,cap_net_admin,cap_perfmon,cap_sys_admin+ep ~/toolchains/spinel-ebpf-run/gpu_host_probe.<pid>
```

It passed in 10 s, as the scratch copy did (three series of count 50, the
negative control refused with FATAL and nothing pushed). The copy was deleted
and the directory left empty.
