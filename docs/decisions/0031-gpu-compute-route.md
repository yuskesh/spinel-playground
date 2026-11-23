# 0031: Ruby compute kernels to WebGPU and CUDA through MLIR

- Date: 2026-11-09
- Status: Accepted by the owner on 2026-11-09; Metal addendum accepted on 2026-11-10.
- Scope: `tools/shader/spinel-rb2comp`, its hosts, and `tests/compute/`.

## Decision

A compute kernel written in Ruby compiles once, through MLIR, to WGSL for WebGPU
and to PTX for CUDA. SPIR-V is canonical; WGSL is naga's translation of it. Ruby
never generates WGSL or MSL directly. This does not replace the Metal route, and
it changes nothing about `shader_def`.

```
kernel.rb -> dump-ast + typedump -> subset check -> emission.mlir
                                                     |- SPIR-V -> spirv-val -> naga -> WGSL
                                                     `- NVVM -> PTX
```

## Input

`gpu_buffer :name, :f32|:i32|:atomic, slot` with contiguous slots from 0,
`gpu_shared :name, :f32|:i32, length`, `gpu_workgroup N` (1 to 256), and exactly
one method named `kernel__<name>` with no parameters. Values: `gpu_global_id`,
`gpu_local_id`, `gpu_group_id`, `gpu_group_size`, `gpu_load`, `gpu_shared_load`.
Statements: `gpu_store`, `gpu_shared_store`, `gpu_barrier`, `gpu_atomic_add`.
The Metal route's `:float` and `:int` are refused, because `:int` is 64-bit there.

Calls to the `gpu_*` builtins are rewritten to typed `__sp_gpu_*` methods, so that
Spinel's own inference types the kernel. `__sp_gpu_` names are reserved.

## Semantics

Integers are i32 and floats are f32. Mixing them is refused; v1 has no
conversions.

| Operation | Contract |
|---|---|
| `+ - *`, unary `-`, `<<` | two's complement wrap, no `nsw` or `nuw` |
| `a / b` | floor; `b == 0` gives 0; `b == -1` gives `0 - a`, wrapping |
| `a % b` | takes the divisor's sign; `b == 0` and `b == -1` give 0 |
| `<<`, `>>` | shift count masked by 31; `>>` is arithmetic |
| comparisons | signed |

Only floor rounding of negative quotients matches Ruby. The rest is this route's
own contract. `arith.select` does not branch, so a divisor of 0 or -1 is replaced
before the division, not after it.

Operations are limited to: Float `+ - * /`, unary `-`, `Math.sqrt`, comparisons;
Integer `+ - * / % << >> & | ^`, unary `-`, comparisons; Boolean `&& || !` only
as the condition of an `if`. `&&` and `||` short-circuit, since the right side
often guards an index. A local assigned only inside an `if` or `times` is not
visible after it.

`gpu_barrier` is allowed only where every invocation reaches it the same number
of times: at the kernel's top level, or in a `times` with a literal count and no
enclosing `if`. Anything else is refused.

An out-of-range buffer index in a kernel is undefined; v1 does not check it. Byte
copies between the host and the device are always checked. Reading `gpu_shared`
memory before writing it is undefined: WebGPU zero-initialises it and CUDA does
not.

Anything the generator does not understand is refused with exit 3, including a
body with `rescue` or `ensure`, an argument to `times`, and a block on a builtin.

## Host

`Unit.open(n)`, `Unit.<buffer>_write(io_buffer)`, `Unit.dispatch(n)`,
`Unit.<buffer>_read(io_buffer)`, `Unit.close`. A `gpu_load`-only buffer has only
a write method, and a `gpu_store`-only buffer only a read method. One unit per
process, one way through not open, open, closed. Both hosts apply the same rules:
`n > 0`, `n` a multiple of the workgroup size, at most 65535 workgroups, `n` no
more than the opened capacity. Every buffer holds `n` elements and is zeroed at
open. A failure raises in Ruby.

The artifact (WGSL or PTX) is embedded in the generated `<unit>_host.rb`, so a
stale artifact cannot be paired with its host.

On WebGPU the `IO::Buffer` passed to a read stays valid across the wait: JSPI
suspends the whole wasm stack, so no Ruby runs until the call returns, and the
host refuses a second call from JS.

## What the first probes changed

These were measured before implementation, on upstream LLVM 23.1.1 and naga
29.0.0, and each is now fixed by a test.

- **CUDA entry ABI.** The bare-pointer convention does not accept a dynamic
  memref, so the entry takes the expanded form, five arguments per buffer:
  allocated, aligned, offset, size, stride. `layout.tsv` records it as
  `memref-expanded-5`.
- **Shared memory on SPIR-V.** `convert-gpu-to-spirv` does not lower `func.func`
  and workgroup attributions do not lower. Shared memory goes through a marker
  buffer whose accesses alone are rewritten to a `Workgroup` variable after
  lowering. On NVVM the shared functions are replaced by address-space 3 accesses.
- **Signed operations through naga.** naga emits signless `SDiv` and
  `ShiftRightArithmetic` as `u32` operations. The SPIR-V exit casts their operands
  to `si32`. Without that, 9 of the 16 rows of the integer table were wrong.
- **`arith.remsi` is never emitted**, because naga rejects its `SNegate` on a
  signless value. `%` is computed from the guarded quotient.
- **`math.sqrt` on NVVM** lowers to a call of `__nv_sqrtf`, which only libdevice
  defines. The exit uses the `llvm.intr.sqrt` intrinsic instead.

## Validation

`tests/compute/run.sh` checks refusals, both exits, the body allowlist, and the
results of six kernels against hand-written values on the CUDA host and on
headless Chromium's software WebGPU adapter. Its controls plant a shared-memory
index error, a non-atomic count and unsigned division, and each must be seen. A
run that skips a host exits 2 and does not count as passing it.

## Addendum: the Metal host (2026-11-10)

`--host metal` runs a kernel natively on macOS 13 or later. Input, integer semantics and the
Ruby API are those above. MSL is naga's translation of the same SPIR-V; Ruby still
never generates it directly. This does not retire the older Metal route. The host
is `tools/shader/sp_metal_compute.m`, with the checks and texts of the CUDA host.

**Bindings.** naga's CLI cannot choose Metal bindings and marks each argument
`[[user(fakeN)]]`, which Metal ignores. naga also drops a buffer the kernel never
uses, so Metal's own numbering would silently move the later buffers. The generator
rewrites the entry's argument list to `[[buffer(K)]]`, with K from the argument's
name, and `[[threadgroup(i)]]`. `_buffer_sizes` gets the index after the last
buffer, but the host does not bind it, so MSL that reads it stops the build.
Anything unexpected in the list also stops the build, with exit 4.

**Shared memory.** Metal gives a wrong result, with no error, when a threadgroup
argument has no length. The host takes each length and index from the pipeline's
reflection and rounds the length up to a multiple of 16. naga zeroes shared memory
in its MSL, but reading it before writing stays undefined.

**Limits.** Beyond the common rules, the host refuses a workgroup over
`maxTotalThreadsPerThreadgroup` and shared memory over
`maxThreadgroupMemoryLength`. Both are device limits.

**Floats.** The host compiles with `mathMode` Safe, or `fastMathEnabled = NO`
before macOS 15. NaN and infinity results are not promised on any host: WGSL allows
an implementation to assume they do not occur.

**Validation.** `tests/compute/run.sh` runs on macOS the same kernels and
hand-written values, without and under Metal's debug layer. Its controls plant a
shared-memory index error, a non-atomic count, removed bindings and a removed
shared-memory length. The controls run without the debug layer, so no fault has
been shown to trip it. A missing device is not tested on Metal, because a device
cannot be hidden from a process, and no run has reached the host's check for a
nil encoder. A host that does not exist on the OS is N/A, not a
skip.
