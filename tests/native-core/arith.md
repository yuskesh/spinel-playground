# Native scalar arithmetic acceptance

`arith.sh` tests the revised decision 0015 through the product driver, with
hand-written stdout, stderr and exit-status expectations. It runs no CRuby
and derives no expected arithmetic answers from generated code or another
implementation. The revised contract requires the upstream pin move and the
vendor abort-entry patch before execution.

Build the pinned compiler, contract reader and native tools using
`docs/building.md`, then run from the repository root:

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 tests/native-core/arith.sh
```

Ruby is required (`RUBY` selects it; the default is `ruby` on `PATH`).
`SPINEL_CORE_BUILD`, `SPINEL_TYPEDUMP`, `SPINEL_SEAM`, `CLANG`, `CC` and `NM`
select matching tools as in the other native checks.
The script supplies Clang and llvm-nm defaults from `LLVM_PREFIX`. The driver
owns platform linking and symbol handling, including Mach-O's leading
underscore and Linux's libcrypt. Native execution on macOS must be measured
there; a Debian result is not macOS acceptance evidence.

The fixtures under `fixtures/arith/` use the root `calculate`:

| Fixtures | Observable contract |
|---|---|
| `add_ok`, `explicit_raise`, `sub_ok`, `mul_ok`, `neg_ok`, `parenthesized` | ordinary arithmetic and parenthesised combinations |
| `add_overflow`, `sub_overflow`, `mul_overflow`, `neg_overflow` | RangeError on signed overflow, including intermediate INT64_MIN |
| `div_pos_neg`, `div_neg_pos`, `mod_pos_neg`, `mod_neg_pos` | floor division and remainder with the divisor's sign |
| `div_zero`, `mod_zero` | ZeroDivisionError, exit 1 |
| `div_min_neg_one`, `mod_min_neg_one` | RangeError for division, zero remainder |
| `return_min`, `intermediate_min` | INT64_MIN returned normally or used internally |
| `and_ok`, `and_neg`, `and_min`, `or_ok`, `or_neg`, `xor_ok`, `xor_neg`, `xor_min`, `not_ok`, `not_max`, `not_min`, `mask32`, `set_clear` | `& \| ^ ~` (decision 0042 stage 1), including negative operands and INT64_MIN; the core object has no undefined symbol, since none of the four can fail |
| `field`, `field_var` | a masked field divided and recombined. In `field` the mask bounds every value, so the failure arms in the core MLIR are gone from the object and it has no undefined symbol; with a variable divisor (`field_var`) `spc_core_fail` stays |
| `shl_ok`, `shl_values`, `shr_values`, `pack` | `<< >>` (decision 0042 stage 2) under S1: negative counts, counts of 64 and more, `-1 << 63` is INT64_MIN; the object keeps `spc_core_fail` |
| `shl_overflow`, `shl_count`, `shr_neg_count`, `shr_min_count` | a left shift that loses bits, `1 << 63`, `1 << 64`, `1 >> -63` and `1 >> INT64_MIN`: RangeError `integer overflow in <<`, exit 1 |
| `field_shift` | `((r >> 4) & 0xf) * 100 + (r & 0xf)`: a constant count in range cannot fail and the mask bounds the rest, so the object has no undefined symbol |
| `abs_ok`, `abs_values`, `abs_min` | `abs` (decision 0042 stage 3): INT64_MAX and `INT64_MIN + 1` have one, and `INT64_MIN.abs` is RangeError `integer overflow in abs`, exit 1 |
| `pow_ok`, `pow_values`, `pow_const`, `pow_const63` | `**` (decision 0042 stage 3), the exact power: `0 ** 0` is 1, `(-2) ** 63` is INT64_MIN, `3 ** 39`, -1 and 1 to the power INT64_MAX, and the constant exponents 0, 1, 2 and 63 |
| `pow_overflow`, `pow_big_exp`, `pow_const_overflow` | a power past the width, `2 ** 63`, `2 ** 64` and `3037000500 ** 2`: RangeError `integer overflow in **`, exit 1 |
| `pow_negative` | `7 ** -1`: RangeError `negative exponent`, exit 1 |
| `fnv32`, `fnv64`, `crc32` | decision 0042 stage 4's named forms against published check values: FNV-1a 32 and 64 of `"a"` and `"foobar"`, and CRC-32 of `"123456789"`, the bytes passed as literal arguments and the starting value in the root. `fnv64` has no undefined symbol: a `w64` form cannot fail |
| `u32_lit` | `core_u32(0xdeadbeef)` is -559038737, a constant; no undefined symbol |
| `bom` | a UTF-8 byte order mark before a first line of code: the prelude goes after the mark in the reader's copy and in `hosted.rb`, and `core_w32_add(7, 1)` prints 8 |
| `w64_add_values`, `w64_mul_values`, `w64_shl_values`, `u64_ge_values` | five rows each of a `w64` form or a `u64` comparison: the low 64 bits read as signed, a shift by 64 or more is 0, a negative count shifts right; no undefined symbol |
| `u64_shr_values`, `w32_shl_values` | five rows each; the count or the i32 operand check keeps `spc_core_fail` |
| `intrinsic_operand`, `u32_shr_count`, `u64_shr_count` | an operand outside the i32 range and a shift count outside 0..31 or 0..63: RangeError with the hosted prelude's text (`core_w32_add: an operand is outside the i32 range`, `core_u32_shr: the count is outside 0..31`, `core_u64_shr: the count is outside 0..63`), exit 1 |
| `reject_def_intrinsic` | an unused top-level definition of an intrinsic's name, refused with conflicting-intrinsic |
| `reject_u32_param`, `reject_u32_wide`, `reject_intrinsic_self`, `reject_intrinsic_arity` | `core_u32` of a parameter and of 4294967296, and an intrinsic with a receiver (unsupported-intrinsic-call), and with one argument too few (arity-mismatch) |
| `reject_array_shl`, `reject_reopen_shl` | `<<` on an Array local (heap-operation) and a reopened `Integer#<<` (binding-environment) |
| `reject_bool_bitwise` | `&` on boolean operands, refused with type-evidence |
| `reject_at_exit`, `reject_rescue`, `abort_hooks` | current envelope refuses each with binding-environment |
| `abort_hooks` runtime execution | retained as PENDING until the envelope admits the constructs |

`return_min` must print `-9223372036854775808\n`, with empty stderr and exit 0.
The full signed range is an ordinary value domain after the upstream pin
move. `intermediate_min`, `mod_min_neg_one` and `div_min_neg_one` exercise
that domain inside core; they no longer distinguish core from hosted
execution through the old pin's nil sentinel.

`wrap` and `promote` refusal checks reuse `add_ok` and require the diagnostic
to name core compilation, `--int-overflow`, and the rejected mode. An
`unknown argument` diagnostic is a failure. `explicit_raise` supplies
`--int-overflow raise` and must build and print 42, so an entirely unsupported
option cannot pass the mode tests. Runtime failures must have exit status 1
and exact specified stdout and stderr.

The uncaught stderr format was characterized with a hosted
`raise RangeError, "integer overflow in +"` probe at `573aa44`, and confirmed
with the rebased upstream abort-entry tip `3c4984057`: it prints
`integer overflow in + (RangeError)\n` and exits 1. This characterizes
formatting only; arithmetic answers remain hand-derived. Unary minus uses
the pinned operator spelling `-@`.

The retained `abort_hooks` fixture has rescue and ensure markers and an at_exit
marker. Its intended future runtime stdout is only `at_exit\n`, with stderr
`integer overflow in + (RangeError)\n` and exit 1. Runtime delivery is PENDING
because the current envelope refuses these constructs. The active refusal
case checks binding-environment and absence of an executable. Two additional
fixtures isolate top-level at_exit and rescue around the selected call, so an
unrelated top-level construct cannot satisfy those refusal checks. Pending
cases are reported separately and are not executed coverage. The vendor
abort entry has a separate validation path outside this source envelope.

For every successfully built runtime case, a forwarding C compiler wrapper
(a Ruby script the run writes) copies the exact `core.o` operand passed by the driver to its final linker
invocation before cleanup. It forwards compiler arguments unchanged and does
not generate substitute objects. llvm-nm reads that copy, independently of the
artifact gate verdict: its undefined-symbol set must be exactly
`spc_core_fail`. The existing non-arithmetic `lower` fixture is built by the
same driver and must have no undefined symbols. One Mach-O ABI underscore is
normalized. The hook is `void spc_core_fail(int32_t kind, int32_t op)`
(noreturn), with kind 1 for overflow and kind 2 for zero division. There is
no unrepresentable-result kind after the pin move. The symbol test checks
dependency identity; runtime cases check observable failure classes and
operators, rather than asserting the hook's machine-level argument values.
The vendor core-seam suite separately checks routing with a substituted core
object and a missing definition.

This revision awaits execution with the integrated pin and arithmetic
implementation; earlier RED counts do not describe it. A build that silently
wraps must fail `add_overflow`, even if its ordinary cases pass. Execution of
a deliberately sabotaged emitter is owned by the integration runner. macOS
execution is still unmeasured.
