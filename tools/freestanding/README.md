# tools/freestanding — declaring a core boundary

A core function is an ordinary Ruby method with a boundary declaration next to
it. The declaration is what the generator reads; the method body is what it
compiles.

## Integer width

The body uses the target's pointer width: `i32-internal` on Cortex-M33,
RV32 and wasm32, and `i64-internal` on 64-bit hosts. The profile must agree
with its target triple. A first-line `# spinel: int64` is refused on a
32-bit target (`int-width-int64-refused`, naming the file, the line and the
table) unless `tools/core/int64-allow.tsv` lists the source, which then
builds at 64 bits as before; an unlisted source's `:i64` scalar boundary is
refused there too. On a 64-bit target the declaration changes nothing. Buffer element widths stay separate.

`spinel-typedump --int-width=32` selects the same upstream literal and type
classification used by that body. Out-of-width Bignum literals are refused.
Run `ruby tests/freestanding/int-width/run.rb` with `LLVM_PREFIX` set to check
the 32-bit overflow boundary, the listed and the refused declaration, the
table's own errors, the 64-bit host, and the width/literal refusals.

## Files

- `spinel/freestanding.rb` — the declaration surface. `freestanding_def` does
  nothing at run time and records the boundary at compile time. Copy or require
  it from beside the kernel you are compiling.
- `profiles/x86_64-linux-host.yaml` — the host profile used by the acceptance
  checks.
- `profiles/cortex-m33-zephyr.yaml`, `riscv32-zephyr.yaml`, `wasm32-worker.yaml`
  — the cross targets, in the pre-T5 form. Kernels built with them run on QEMU
  Cortex-M33, QEMU RV32 and wasm32 in [the target lanes](../../tests/freestanding/README.md).
- `profiles/zephyr-cortex-m33.yaml`, `zephyr-riscv32.yaml`, `workers-wasm32.yaml`
  — the same targets in the platform-first form: a platform, an arch and what
  the platform supplies. They expand through the platform ledger
  [`tools/platform/menus.yaml`](../platform/menus.yaml), which names the pre-T5
  profile each one is based on.

## Declaring

```rb
require_relative "spinel/freestanding"
freestanding_def :add, params: [:i32, :i32], returns: :i32
def add(a, b)
  a + b
end
```

`params` and `returns` give boundary widths. Inference already establishes that
the method computes on `Integer`; what it cannot establish is whether the
foreign C side wants `int32_t` or `int64_t`, so the declaration states it.
Bodies compute in 64 bits and the declared width applies at the boundary, where
a value that does not fit traps rather than being truncated.

`overflow:` is `:trap` by default and may be `:wrap` per declaration. `:raise`
is refused: raising needs a heap and a setjmp stack that a core object does not
have.

Buffer parameters (`[:f64_buf, :in]` followed by `:len`) and `bounds:` are
exercised on the cross targets by the `e077` lane, and buffers passed to
platform externs by `e083`'s reject table; see
[the target lanes](../../tests/freestanding/README.md). The host acceptance
checks still do not cover them.

## Profiles

A profile states the target triple and cflags, the ABI, what runtime the object
may reach, and which platform externs it may call. The generator and the
undefined-symbol gate read the same file, so a build cannot tell one of them
something different from the other.

Both forms are accepted. A pre-T5 profile states everything itself. A
platform-first profile names a platform, an arch and what the platform supplies,
and the emitter expands it through the ledger `tools/platform/menus.yaml`, which
it finds from its own location or takes from `--menus`. The pre-T5 form is
reported as deprecated and accepted unchanged. `tests/freestanding/profiles`
checks that every shipped profile of each form is read, and that each
platform-first profile emits an object for its own target.

## Building and checking

See [Building and testing](../../docs/building.md). Provenance for both files is
in [provenance](../../docs/provenance.md).
