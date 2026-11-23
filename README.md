# Spinel Extended

> **This is an experimental repository.** It is a place to try ideas, not a
> product. Anything here (the routes, the command lines, the ABIs, the file
> layout, even whether a feature exists at all) can change or disappear at any
> time, without notice and without a deprecation period. There are no releases,
> no compatibility promises and no support. If you build on it, pin a commit and
> expect to adapt when you move.

A Ruby AOT compiler project built on Spinel. It connects source analysis,
checked compilation boundaries and runtime integration to native programs,
freestanding kernels, edge modules and GPU or eBPF artifacts.

The compiler is pinned under `vendor/spinel`. Build requirements and commands
are in [Building and testing](docs/building.md); runnable programs are indexed
in [Examples](examples/README.md). Each route below has its own source subset,
ABI, dependencies and validation scope.

## Native core and hosted Ruby

On Debian x86_64 and macOS arm64, the Extended driver can select an ordinary
Ruby method and link its native core object into a hosted executable. The
selected closure is checked for allocation and runtime independence before
linking. The executable still contains the hosted Spinel runtime and GC.

The ordinary-source `--core` route currently admits inferred integer literals,
comparisons, conditional selection, local bindings, signed 64-bit `+ - * / %`
and unary `-`, the bitwise `& | ^ ~`, the shifts `<< >>`, `abs` and `**`
([decision 0042](docs/decisions/0042-core-bit-and-power-operators.md)), and
the named word forms (decisions 0022 and 0042: wrapping `core_w32_*` and
`core_w64_*`, unsigned `core_u32_*` and `core_u64_*`, and `core_u32(LIT)`) in a
bounded single-file envelope. Overflow (including a `<<` that loses bits and a
power past 64 bits), a negative exponent, a word form's operand or count out
of its range and a zero divisor end
the program as an uncaught `RangeError` or `ZeroDivisionError` would
([decision 0015](docs/decisions/0015-core-scalar-arithmetic.md)). Allocation,
unknown bindings and unsupported calls are refused. See the [supported envelope](docs/native-core/supported-envelope.md)
and [reproduction guide](docs/native-core/reproducing.md). Checks:
[native driver](tests/native-core/driver.sh), [input ledger](tests/native-core/ledger.sh)
[arithmetic](tests/native-core/arith.sh) and [source eligibility](tests/core-eligibility/run.rb).

The separate checked **CORE boundary** admits numeric and buffer computation
under an explicit contract, with checked arithmetic and status-returning
failures. Full owns storage and lends buffers through generated adapters.
Its [boundary guide](docs/core/buffer-boundary.md) and
[acceptance suites](tests/core-boundary/run.sh) define the widths, sizes,
mutability, aliasing and failure rules. Declared standalone functions also have
[a C-callable object route](tools/freestanding/README.md), checked by
[the native core suite](tests/core/run.sh).

## Implemented routes and examples

These are bounded capabilities with their own checks, rather than support for
arbitrary Ruby on every target. Platform requirements and unavailable checks
are documented by each suite.

| Route | Current behavior and limits | Validation |
|---|---|---|
| [DOOM](examples/doom/README.md) | Hosted CPU play and headless replay; a native CORE input/step/render route when built with its entries. Full provides setup, storage and display. The complete game is not a standalone core artifact. | [hosted](tests/doom/run.sh), [CORE lanes](tests/doom-core/run.sh) |
| [Freestanding targets](tests/freestanding/README.md) | Declared kernels, buffers, traps and platform externs on Cortex-M33 and RV32 under Zephyr/QEMU, and wasm32 under node/workerd. Each profile states its ABI and allowed externs. | [target lanes](tests/freestanding/run.sh) |
| [CORE applications on Zephyr](docs/core/applications.md) | State, timer entries, channels and board members compiled into firmware, with stack/provider/interrupt checks and trace verification. `mps2/an521` runs under QEMU; FRDM-MCXN947 is build-checked, not board-run. | [application suites](tests/app/run.sh) |
| [WASM and edge](tools/wasm/README.md) | `wasm32-wasip1` programs and Workers/Fastly packages, including KV, R2/D1 and the device/edge audit example. Checks use local workerd, Viceroy and QEMU. Integer is 32-bit on this route; threads are refused, `Fiber` and `Enumerator.new` are rewritten into stackless state machines within the limits of [decision 0035](docs/decisions/0035-stackless-fiber.md), and host APIs require explicit selection. | [edge examples](tests/edge/run.sh), [request arena](tests/edge/arena.sh), [stackless Fiber](tests/fiber/run.sh) |
| [Tensor](examples/tensor/README.md) and [image](examples/image/README.md) | `tensor_def`, `assign!` fusion and StableHLO imports through IREE, on CPU and the Apple GPU with Metal. Reduction order and floating-point contraction are explicit contracts. | [tensor/image suite](tests/tensor/run.sh) |
| [Automatic differentiation](tools/grad/README.md) | Enzyme-based gradients for the declared allocation-free floating-point subset, with type, allocation, numeric and determinism gates; declared freestanding gradient lanes also exist. | [host gradients](tests/grad/run.sh), [target gradients](tests/freestanding/run.sh) |
| [DOOM GPU raster](tools/raster/README.md) | Job IR gather kernels through IREE/Metal render the DOOM 3D view; job bounds and ordering are checked. The runner checks demo completion and GPU frame counts, without claiming a CPU-oracle comparison. | [raster suite](tests/raster/run.sh) |
| [Shaders](tools/shader/README.md) | A declared Float shader subset becomes SPIR-V, WGSL and MSL; conversion, refusals and device drawing have separate checks. Metal and WebGPU require their named runtimes. | [shader suite](tests/shader/run.sh) |
| [eBPF Ruby integration](tools/ebpf/README.md) | Linux HTTP-server dispatch, counters, worker selection, XDP responses/rejection and a probe DSL. Kernel loading needs the documented capabilities. | [unprivileged](tests/ebpf/run.sh), [live kernel checks](tests/ebpf/live.sh) |
| [SpBPF and Go](examples/ebpf-go/xdp-counter/README.md) | SpBPF MLIR verification/ELF generation, Go bindings and an XDP counter. Live attach/count/ring-buffer checks are separate from object-generation tests. | [SpBPF](tests/spbpf/run.sh), [Go generation](tests/ebpf-go/run.sh), [live](tests/ebpf-go/live.sh) |

The [examples index](examples/README.md) also includes spinel-vi and mvc-blog,
with [editor](tests/spinel-vi/run.sh) and [blog](tests/mvc-blog/run.sh) checks.
GPU execution is platform-specific; a CPU-only tensor run reports Metal checks
as unavailable. Local edge checks establish local behavior, not a production
cloud deployment. [Workers limits](docs/edge/workers-limits.md) records the
measured deployment constraints.

## Memory and platform contracts

`core` means no allocation or Spinel runtime/GC dependency throughout the
reachable closure; platform externs require an explicit contract. `full` is
hosted execution with the Spinel runtime and GC. Memory policy and target
capabilities are separate axes.

A native build without a collector is upstream's `--gc=none`
([decision 0003](docs/decisions/0003-gc-and-arena-build-modes.md), revised
2026-11-01): nothing is reclaimed until process exit, and `GC.start` is a
no-op. [The pair suite](tests/gc-arena/run.sh) compares it with the collected
build; threads, C extensions and `--exceptions=abort` are accepted upstream and
not verified here. The WASM request-arena configuration is a command-mode
`--gc=none` build checked by [the request-arena suite](tests/edge/arena.sh);
instance death reclaims its memory. Neither implements a scoped arena coexisting with a collected heap. The
request-arena suite separately records a known Integer catch/throw codegen
defect shared with the ordinary build; that case is not counted as correct.

**Proposed, not implemented:** scoped arena/GC coexistence and a complete
freestanding DOOM deployment. Existing target profiles and native CORE routes
do not establish those capabilities. See the [roadmap](docs/roadmap.md).

## Development

The project is initially developed privately with the intention of becoming a public repository.

Spinel Extended is a separate project and does not imply upstream endorsement.
Predecessor projects are migration references, not build dependencies. Imported
components retain their notices and recorded revisions.

- [Building and testing](docs/building.md): dependencies, commands and suite prerequisites.
- [Architecture](docs/architecture.md): responsibilities and dependency boundaries.
- [Roadmap](docs/roadmap.md): delivered scope and remaining acceptance work.
- [Dependency provenance](docs/provenance.md): source revisions, notices and historical evidence.
- [Contributing](CONTRIBUTING.md) and [decisions](docs/decisions/README.md).

Maintained documentation is written in English.

## License

Spinel Extended is licensed under the Apache License 2.0 with LLVM Exceptions
(`Apache-2.0 WITH LLVM-exception`); see [LICENSE](LICENSE) and [NOTICE](NOTICE).
The exceptions matter for a compiler: code of this project that compiling
embeds in your program needs no attribution there, and where the licence
would conflict with GPLv2 in a combination with GPLv2 code, the conflicting
sections may be waived. Imported components keep their own licences, listed
with their texts in [THIRD_PARTY.md](THIRD_PARTY.md); DOOM is GPL-2.0 and is
distributed as source only, without a WAD.
