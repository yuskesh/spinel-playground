# tools/ebpf -- spinel-ebpf

A Ruby program compiled by the pinned Spinel, with the methods that can run in
the kernel compiled to eBPF: an HTTP server whose L7 counters live in BPF maps,
SO_REUSEPORT worker selection in the kernel, a kernel-side static response
through XDP, XDP early reject, and a probe DSL for
observability programs that export OTLP. Ported from spinel-ebpf
at `23fa4b0` (2026-08-26) as one unit; see [provenance](../../docs/provenance.md).

The tree keeps spinel-ebpf's own layout: `bin/spinel-ebpf` (the CLI),
`src/spinel_ebpf` (partition, dispatch, plugin, consumer DSL),
`src/codegen_c` (the production eBPF codegen, in C), `src/runtime` (the host
runtime and the OTLP exporter), `include/spnl`, `tools` (gates and
generators), `tests`, `examples` and `benchmarks`.

## Build and use

```sh
make -C vendor/spinel deps && make -C vendor/spinel     # the pinned compiler, with Patch 1
make -C tools/ebpf/src/codegen_c                        # the eBPF text codegen
export NANOPB_DIR=/path/to/nanopb-0.4.9.1               # docs/toolchains/spinel-ebpf-deps
tools/ebpf/bin/spinel-ebpf compile tools/ebpf/examples/http_server/M002/server.rb \
    -o /tmp/m002 --build --ebpf-dispatch
```

`--ebpf-dispatch` compiles the methods partitioned to eBPF into the object and
routes the native calls to them through `bpf_prog_test_run`; it uses the
vendor's `SPINEL_EXTERN_METHODS` (Patch 1). The in-process codegen binary is
linked from the vendor's compiler objects on first use, into
`tools/ebpf/build/`. The compiler is `vendor/spinel` unless `SPINEL_DIR`
names another.

Running a program that loads BPF needs `cap_bpf`, `cap_net_admin` and
`cap_perfmon`. The checks grant them to the one binary with `setcap`, on a
filesystem mounted without `nosuid` (file capabilities are ignored there).

## Checks

- `tests/ebpf/run.sh` (no privilege): the minitest files (1459 runs) and the
  seven runtime harnesses that need neither Python, macOS, spinel-llvm, AMP
  firmware nor protoc.
- `tests/ebpf/live.sh` (privileged, as above): the HTTP server milestones M002
  (L7 counter) and M003 (SO_REUSEPORT selection), M004's kernel-side response
  (`tcp_slice.rb`, `ruby_slice.rb`), and XDP early reject
  (`examples/observability/otlp/access_enforcer.rb`), each checked for its
  documented effect.

## Not run here

- **Oracles and benchmarks**, kept as files: `benchmarks/` (the nginx
  comparisons), the golden and baseline gates (`tools/golden.rb`,
  `golden_compile.sh`, `stage2_verify.sh`, `form_verify.sh`, `reach_gate.rb`),
  `run_otlp_kernel_e2e.sh` (below), and the MLIR shadow
  (`src/spinel_ebpf/mlir_backend.rb`), which compares this codegen with
  spinel-llvm's.
- **Other hosts or trees**: the AMP firmware lane
  (Zephyr M7/M33 boards), and everything that needs spinel-llvm
  (`SPNL_LLVM_ROOT`, `SPNL_SPBPF_COMPILE`): the product gate, the MLIR harnesses
  and three minitest files.
- **M004's `server.rb`** uses `xdp_match_health`, which spinel-ebpf withdrew in
  E406; `tcp_slice.rb` is its successor and is checked.
- The observability examples (75 entries) and the rest of the HTTP examples are
  imported; the live checks cover the server's eBPF programs and XDP early
  reject only.

## Local changes

- The compiler is `vendor/spinel` (spinel-ebpf: `third_party/spinel`). The
  in-process codegen also links the vendor's `build/regexp/*.o`, which the
  pinned compiler's `re_lit_check.o` needs.
- nanopb and mbedTLS come from `NANOPB_DIR` and `MBEDTLS_DIR` (spinel-ebpf:
  submodules under `third_party/`), in `bin/spinel-ebpf`,
  `scripts/build-mbedtls.sh` and 21 harnesses.
- No tracked file names a sibling checkout: the defaults that pointed at
  a sibling `spinel-llvm` checkout are removed, and the variables must be
  set. Source paths name the predecessors by name only (2026-10-30).
- Lab host addresses are documentation addresses (RFC 5737, `192.0.2.x`)
  and names (`host.example`): in `benchmarks/results/E188/summary.md`,
  `examples/amp_m7_firmware/README.md`, the `provision-grafana.sh` usage
  comment and the `incident_probe.rb` usage comment (2026-10-30). The
  synthetic NAT and load-balancer addresses, the namespace-local test
  addresses and the k3s default CIDRs are unchanged.
- `tests/spinel_ebpf/partition_test.rb` reads the vendor's `types.c`;
  `reuseport_select_test.rb` reads `examples/http_server/so-reuseport/server.rb`,
  imported from the public `yuskesh/spinel-ebpf` at `58e6ca3`.
- The four Python files (three OTLP mock servers and a benchmark payload
  generator) are not imported. The three mock servers are written here in
  Ruby instead (below).

## The OTLP harnesses and their mock receivers

Twelve harnesses under `tests/runtime/` send OTLP to a mock receiver started
on 127.0.0.1: `run_otlp_send`, `_grpc`, `_extras`, `_tls`, `_tls_smoke`,
`_audit_span`, `_http_span`, `_http_duration`, `_metric_series`, `_xlayer`,
`_kernel_e2e` and `run_gpu_host_probe`. The receivers are this repository's
own, written in Ruby for CRuby (2026-10-24) to the behaviour of spinel-ebpf's
Python mocks, which were not imported:

- `mock_otlp_receiver.rb`: OTLP/HTTP, and HTTPS (`--cert`), and mTLS
  (`--client-ca`).
- `mock_otlp_grpc.rb`: OTLP/gRPC over HTTP/2 with prior knowledge, and grpcs
  with ALPN `h2` (`--cert --key`). HTTP/2 and HPACK (`mock_hpack.rb`) are
  written here; they take any conforming client, which is checked with curl.
- `mock_tls_server.rb`: the HTTPS peer of `run_otlp_tls_smoke.sh`.

A protobuf body is captured as `protoc --decode` text, so these harnesses
check the sender against protoc. Each mock starts under `setsid`, and the
harness stops its process group. They are not oracles (the owner,
2026-10-24, [decision 0020](../../docs/decisions/0020-oracle-gate.md)):
protoc reads the format, and nothing is compared with another
implementation's output. The exception is `run_otlp_kernel_e2e.sh`, which
also compares three paths over the kernel's records and is gated as an
oracle (`ALLOW_ORACLE=1`). The others need no switch; they run by hand, with
the variables below, and no suite runs them.

| Variable | What it names |
|---|---|
| `NANOPB_DIR` | nanopb 0.4.9.1, the encoder the senders compile in |
| `PROTOC` | protoc (default `protoc` on `PATH`) |
| `OTEL_PROTO_DIR` | the opentelemetry-proto checkout protoc reads; without it, `third_party/opentelemetry-proto` here |
| `MBEDTLS_DIR` | mbedTLS 3.6.6, for `run_otlp_tls.sh` and `run_otlp_tls_smoke.sh` |
| `RUBY` | the CRuby that runs the mocks (default `ruby`) |
| `EBPF_CAP_DIR` | `run_otlp_kernel_e2e.sh` and `run_gpu_host_probe.sh`: a directory on a filesystem without `nosuid`; the probe is copied there, given capabilities with `$SUDO setcap` (`SUDO` defaults to `sudo`), and deleted afterwards. `run_otlp_kernel_e2e.sh` grants `cap_bpf,cap_net_admin,cap_perfmon`; `run_gpu_host_probe.sh` grants `cap_bpf,cap_net_admin,cap_perfmon,cap_sys_admin`, since its uprobe is refused without `cap_sys_admin` (below). Without it, `run_otlp_kernel_e2e.sh` runs its probe as root or with `sudo -n`, as before. |
| `SPNL_LLVM_ROOT`, `SPNL_SPBPF_COMPILE`, `GO` | `run_otlp_kernel_e2e.sh`: the tree holding `examples/ebpf-go/otlp-agent` (this repository's root), `spbpf-compile` from `tools/mlir/native`, and Go 1.25.14 |
| `SPNL_SPINEL_LLVM_MLIR`, `LLVM_CONFIG` | `run_otlp_kernel_e2e.sh`, through `tools/build_spbpf_schema_check.sh`: this repository's `tools/mlir/native` (built), and the `llvm-config` of its LLVM. The harness also reads `tools/ebpf/build/vmlinux.h` (`bpftool btf dump file /sys/kernel/btf/vmlinux format c`). |

The versions and where they come from are in the
[installation record](../../docs/toolchains/spinel-ebpf-deps/INSTALLATION-RECORD.md).

On Debian 13 (kernel 7.1.8, 2026-10-24) all twelve pass. With
`cap_bpf,cap_net_admin,cap_perfmon` alone, the uprobe of
`run_gpu_host_probe.sh` is refused (EACCES from `perf_event_open`); with
`cap_sys_admin` added it attaches, and the owner approved granting it to that
probe (2026-10-24). The installation record has what was observed.

## tools/ebpf/go -- the Go path (from spinel-llvm)

`tools/ebpf/go` is not part of spinel-ebpf. It comes from spinel-llvm
`463d49dd` (E152) and was placed here, beside the rest of the eBPF tooling:
`spbpf` is a pure-Go builder for SpBPF MLIR, and `cmd/spbpf-bindgen`
generates typed Go bindings from an spbpf schema. With `spbpf-compile`
(`tools/mlir/native`), they build `examples/ebpf-go/xdp-counter`. The checks
are `tests/ebpf-go/run.sh` and `live.sh`; the Go toolchain is recorded in
`docs/toolchains/go-1.25.14`. The module paths keep spinel-llvm's names
(`spinel-llvm/tools/ebpf/go`).
