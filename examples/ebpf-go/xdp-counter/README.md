# xdp-counter -- one Go binary, no external .bpf.o

A Go program that writes an eBPF program, compiles it, and runs it on the
kernel. It uses no MLIR, clang or cgo at run time, because the ELF is
`go:embed`-ed. Ported from spinel-llvm `463d49dd` (E152, E153); see
[provenance](../../../docs/provenance.md).

| | |
|---|---|
| `bpfgen/main.go` | a pure-Go builder (`tools/ebpf/go/spbpf`) that writes `xdp_counter.mlir` |
| `schema.json` | the source of truth: the program, the maps, the record, the telemetry |
| `xdp_counter.mlir` | the builder's output, committed so that regenerating can be checked |
| `objects_gen.go` | typed bindings generated from the schema by `spbpf-bindgen` |
| `main.go` | the binary: attach, read the counter, read the ring buffer, close |

The program: `counts[0] += 1` per packet (an ARRAY map, atomic),
`counts[1] =` the packet's first 4 bytes, one tick record with the current
count into a ring buffer, and verdict pass. `counts[0]` can be read only
through the lookup's checked reference; the lowering makes that a real null
branch.

## Build and run

```sh
tools/mlir/native/build.sh                     # spbpf-compile
cd examples/ebpf-go/xdp-counter
SPBPF_COMPILE=.../tools/mlir/native/build/bin/spbpf-compile \
SPBPF_BINDGEN=/path/to/spbpf-bindgen $GO generate ./...   # builder -> .mlir -> ELF -> bindings
$GO build -o xdp-counter .
./xdp-counter -parse-only                      # checks the embedded ELF, no kernel
./xdp-counter -iface lo -duration 3s           # needs cap_bpf and cap_net_admin, not root
```

`tests/ebpf-go/run.sh` does the generation and the tests, and
`tests/ebpf-go/live.sh` runs the binary on `lo` and checks what it prints.
`kernel_test.go` skips itself without the capabilities.

When the verifier refuses the program, `explainLoadError` in `main.go`
names the program, its schema and its generator beside the kernel's
message. `spbpf-compile` refuses an `.mlir` that disagrees with `schema.json`.

`testdata/kernel/run_xdp_counter.sh` and `run_ringbuf.sh` under
`tools/ebpf/go` are spinel-llvm's own kernel scripts. They run as root in a
network namespace, and are kept as files; `tests/ebpf-go/live.sh` replaces
them with capabilities on `lo`.
