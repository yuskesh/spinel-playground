# What is implemented, and what is refused

Measured on Debian with LLVM/Clang 23.1.1, against Extended `9cacfd4` with the
fork revisions recorded in [Reproducing](reproducing.md). The rejection table
below preserves that Debian measurement. The pinned product path and Mac
fixture/gate evidence are recorded in [macOS validation](macos-validation.md).

**Since that measurement**, [decision 0015](../decisions/0015-core-scalar-arithmetic.md)
admits `+ - * / %` and unary `-` on 64-bit integers, and the pin move to
upstream `e1d92f1e1` admits the literal `-9223372036854775808`. The `a + b` and
reserved-minimum rows below record the earlier envelope. The current arithmetic
behaviour and refusals are checked by [`tests/native-core/arith.sh`](../../tests/native-core/arith.sh).
[Decision 0042](../decisions/0042-core-bit-and-power-operators.md) stage 1 adds
`&`, `|`, `^` and `~`, which are exact and cannot fail. Stage 2 adds `<<` and
`>>` under Ruby's rule: a negative count shifts the other way, `>>` by 64 or
more is 0 or -1, and a left shift that loses bits (`a >> -n` included) ends
the program as `integer overflow in <<` (RangeError). Stage 3 adds `abs` and
`**`: the exact result, or `integer overflow in abs` for `INT64_MIN.abs`,
`integer overflow in **` for a power past 64 bits and `negative exponent`
for a negative exponent (each a RangeError). `**` lowers without a loop.
Stage 4 adds the named word forms of the intrinsic table
(`spinel-mlir/Core/Intrinsics.h`): decision 0022's `core_w32_*`, `core_u32_*`
and `core_fixed_*`, and the wrapping `core_w64_add`/`sub`/`mul`/`neg`/`shl`
and `core_w32_shl`, the unsigned `core_u64_lt`/`le`/`gt`/`ge`/`shr` and the
constant `core_u32(LIT)`. A `w64` form answers the low 64 bits and cannot
fail; a 32-bit form's operand outside the i32 range and a `u32`/`u64` shift
count outside 0..31 or 0..63 end the program as a RangeError with the text
`tools/core/hosted-prelude.rb` raises (`core_w32_add: an operand is outside
the i32 range`, `core_u64_shr: the count is outside 0..63`, ...).
`core_u32` takes only an Integer literal in 0..4294967295; anything else is
refused (`unsupported-intrinsic-call`), and so is a top-level definition of
a table name (`conflicting-intrinsic`). The driver appends the definitions
the source names from the hosted prelude to the hosted copy it compiles, so
the hosted half has the names too; the core object never contains them. As
everywhere on this route, the top level passes only integer literals to the
root, so a call of a word form belongs in the selected closure.

## The implemented commands

```sh
# the whole path
tools/core/spinel-core-build --source app.rb --core <method> -o app

# the pieces, if you need them separately
vendor/spinel/bin/spinel app.rb --core <method> --core-id=<id> --core-map=<map> \
                  --inputs-out=<ledger> --no-line-map -S
tools/mlir/native/build/bin/spinel-core-emit --source app.rb --core-map <map> \
                  -o core.o --clang <clang> [--inputs-out <ledger>]
tools/core/core-artifact-gate core.o <symbol>
tools/mlir/native/build/bin/spinel-core-check app.rb --method <method>
```

`--core` and `--inputs-out` are included in the pinned compiler. Use the
Extended driver for the complete checked and linked artifact.

## The admitted source envelope

One file. One selected top-level method. The method and its statically resolved
helpers may use:

- integer literals within `[INTPTR_MIN + 1, INTPTR_MAX]` for the configured
  target width;
- integer comparison;
- conditional selection;
- local assignment and reads;
- direct calls to other methods in the same closure.

At the top level: method definitions, a direct call into the closure, and
`puts <call into the closure>`. Nothing else.

## What is refused, measured

Each of these was built through `spinel-core-build` and refused. The verdict is
the behaviour; the wording may change.

| program | outcome |
|---|---|
| `a + b` in the body | refused, not eligible |
| `a < b ? a : nil` | refused, not eligible |
| a `Float` argument | refused, not eligible |
| a `String` argument | refused, not eligible |
| a `while` loop | refused, not eligible |
| `pick(-9223372036854775808, 3)` | refused — the reserved minimum |
| no caller in the program | refused — no inference evidence |
| a method that is not in the source | refused |
| `require "json"` | refused — a load recognised and not satisfied from a file |
| a method outside the closure calling into it | refused — unaccounted ingress |
| the acceptance program | **accepted**, prints 3 |

## Runtime presence in the combined executable, measured

This is not a GC-free program and is not presented as one.

| | executable | core object |
|---|---|---|
| size | 868472 bytes | 624 bytes |
| collector entry points defined | 3 | 0 |
| `sp_*` runtime symbols defined | 1664 | 0 |
| undefined symbols | — | 0 |
| exported symbols | — | the mapped symbol only |

The hosted runtime is linked in by design: startup, output and everything else
the program does outside the selected method still goes through it. What is
independent is the **core object**, and that is checked at the object boundary
rather than inferred from the executable.

## Claims not made

- **Not "Ruby works".** Six forms are admitted; the table above is most of the
  language refused.
- **Not arbitrary `i64` inputs.** The admitted domain excludes `INTPTR_MIN`,
  because the hosted printer reserves it — the reason is the consumer, not the
  parameter type.
- **Not a GC-free executable.** See the table above.
- **Not macOS.** Nothing here has been run there.
- **Not reproducible from the pin.** The pin cannot build it.
