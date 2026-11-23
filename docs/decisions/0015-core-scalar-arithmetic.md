# 0015: Integer arithmetic in the native scalar core slice

- Date: 2026-10-18
- Status: Accepted (owner, 2026-10-18), revised the same day before any
  implementation landed: the pin moves to upstream and the abort entry is a
  vendor patch (see "Revision, 2026-10-18"). Implemented on main at
  `7d250ff` (see "Implementation notes, 2026-10-19").
- Scope: Integer arithmetic in methods selected with `tools/core/spinel-core-build --core`
  (the native scalar slice of [decision 0005](0005-native-core-executable.md)):
  - which operators are admitted;
  - what a result outside the Integer range, a zero divisor and the
    `INT64_MIN / -1` pair do;
  - how such a failure leaves the core object and what the hosted program observes;
  - the pin and the vendor patch this needs, and how acceptance is checked.

## Context

The scalar slice admits integer literals, comparison, selection and local
binding. Arithmetic is refused by the checker (`unproved-arithmetic`,
`tools/mlir/native/lib/Core/Eligibility.cpp`). The emitter lowers the slice with
`scalar::OverflowMode::None` (`tools/mlir/native/lib/Core/Emit.cpp`), so lifting
the checker's refusal alone would make overflow wrap silently. Decision 0005
authorised no trap insertion, no exception recovery and no full-domain i64
claim; this record supplies that missing contract.

`--core` is a claim to check, not permission to change semantics. The program
built with `--core` must mean what the same program means without it, so the
reference is Spinel's own integer contract, not CRuby's arbitrary-precision
Integer, which a core object cannot represent.

Upstream Spinel (matz/spinel `master` at `e1d92f1e1`, 2026-10-18, read for this
record) states that contract in `docs/int-overflow.md` and `docs/wasm.md`:

- `Integer` is the target's pointer width: 64 bits on x86_64 and arm64.
- Under the default `--int-overflow=raise`, `+ - *`, unary `-` and a shift onto
  the sign bit that overflow raise `RangeError` (`integer overflow in +`).
- `/` and `%` floor. A zero divisor is `ZeroDivisionError` in every mode.
- Since `a07741ff1` (2026-10-11), the nil of a nullable Integer slot is a flag
  beside the word, so `-2**63` is an ordinary Integer in every mode.
- Since `ea6837508` (2026-10-11), `--exceptions=abort` builds for a host without
  exception handling. A `raise` runs the `at_exit` hooks, prints what an
  uncaught exception prints and traps. An `ensure` around it does not run, and
  constructs that need a frame to catch an exception are refused at compile time.

A core object has the same constraint as such a host: it has no `setjmp` stack and
no runtime to raise into. The freestanding lane already refuses `overflow: :raise`
for that reason (`tools/freestanding/spinel/freestanding.rb`).

The pin at the time of this record, `573aa44`, is based on upstream `8279058d`
(2026-09-21) and still uses `INTPTR_MIN` as the nil sentinel
(`vendor/spinel/lib/sp_types.h`). This was observed on Debian x86_64 with
that pinned hosted build:

- a result equal to `INT64_MIN` prints as nil (an empty line);
- `INT64_MIN / -1` and `INT64_MIN % -1` raise `NoMethodError`, because the
  receiver reads as nil.

## Options

1. **Status return converted to a raise in the hosted caller.** The core object
   returns a status and writes the result through a pointer, as the
   [CORE buffer boundary](../core/buffer-boundary.md) does, and the hosted call
   site raises the exception. The failure would be catchable. But it changes the
   internal prototype, and upstream's own answer for an exception-less host is
   abort, not recovery.
2. **Abort, following upstream `--exceptions=abort`.** A failure reports itself
   as an uncaught exception would and ends the program. Chosen.
3. **Admit arithmetic only where a range proof excludes overflow.** This keeps
   the prototype and needs no failure path. It refuses nearly every method whose
   inputs come from the program, which is the case worth compiling.
4. **Wrap.** This is a silent change of meaning under the default mode, so it is
   not acceptable.

## Decision

**Admitted operators.** These are admitted on integer values the slice already
admits:

- binary `+`, `-`, `*`, `/` and `%`;
- unary `-`;
- parenthesised combinations of these.

`**`, shifts, `abs` and bitwise operators remain refused with their current
diagnostics. Admitting them is future work under this same contract.

**Width.** Arithmetic is on 64-bit signed integers, the pointer width of both
supported hosts.

**Mode.** The contract is upstream's `--int-overflow=raise`, the default. A
`--core` build under `wrap` or `promote` is refused, and the diagnostic names
the flag. `wrap` would need its own record. `promote` needs an allocator, which
core does not have.

**Results.**

| Case | Observed behavior |
|---|---|
| `+ - *` or unary `-` leaves the 64-bit range | `RangeError`, `integer overflow in <op>` |
| `/` or `%` with a zero divisor | `ZeroDivisionError`, `divided by 0` |
| `INT64_MIN / -1` | `RangeError`, `integer overflow in /` (chosen here; upstream's answer for this pair was not checked) |
| `INT64_MIN % -1` | `0` |
| `/` and `%` otherwise | floored quotient and remainder, the remainder taking the divisor's sign |
| an intermediate value equal to `INT64_MIN` | an ordinary value, as upstream specifies |

**Delivery: abort, not raise.** A failure does not return. The core object calls
one failure hook, which takes the failure kind and the operator. The hook is the
core object's only new undefined symbol. The artifact gate admits that symbol by
name and nothing else, and its prototype appears in the generated header.

Extended's generated hosted shim defines the hook in its own translation unit.
The shim does not include the runtime; it calls one runtime entry, added by the
vendor patch below. When the hook is called, the program:

- runs the `at_exit` hooks;
- writes to stderr the text the pinned hosted build prints for the same uncaught
  exception;
- exits with the status an uncaught exception gives.

The failure is not catchable. A `rescue` around a call into core does not catch
it, and an `ensure` around it does not run. This is the `--exceptions=abort`
contract applied to the core call. Unlike upstream, the rest of the hosted
program keeps its exception handling. Today the slice's envelope refuses a
`rescue` around a call into core, and a top-level `at_exit`, so no admitted
program can observe the difference yet. The entry makes the contract hold when
the envelope grows.

**The pin.** The pin moves to upstream `master` at `e1d92f1e1` (2026-10-18) or
later, with the fork's local commits rebased onto it. That revision includes
`a07741ff1`, so `INT64_MIN` is an ordinary value on both sides of the boundary
and is returned like any other result. The move follows the procedure of the
2026-09-21 synchronisation in [provenance](../provenance.md) and is recorded there.

**The vendor patch: an abort entry.** The pinned runtime keeps the `at_exit`
runner, the uncaught-exception printer and the `rescue` frame stack file-local
(`static`), and the only external entry, `sp_raise_cls`, unwinds to the nearest
`rescue`. Upstream is the same at `e1d92f1e1`, and its `--exceptions=abort` is a
whole-program mode for `wasm32-wasi` only. The patch therefore adds one external,
non-returning entry. It takes an exception class name and a message, and does
what an uncaught raise does, ignoring any `rescue` frame:

1. it runs the `at_exit` hooks;
2. it prints the uncaught-exception text;
3. it exits with the uncaught status.

It reuses the runtime's existing uncaught path and changes no existing behaviour.
It is a fork commit on top of the rebased stack, with its own provenance entry.

## Validation

- Every row of the results table is a fixture whose expected stdout, stderr and
  exit status are written into the test by hand. The fixtures include values at
  the edge of each row:
  - `INT64_MAX + 1`;
  - `INT64_MIN - 1` reached inside core;
  - `INT64_MAX * 2`;
  - `-INT64_MIN` reached inside core;
  - `7 / -2`, `-7 / 2`, `7 % -2` and `-7 % 2`;
  - `x / 0` and `x % 0`;
  - `INT64_MIN / -1` and `INT64_MIN % -1`;
  - a returned `INT64_MIN`, printed as `-9223372036854775808`;
  - an intermediate `INT64_MIN` that is not returned.
- A `rescue` around a call into core and a top-level `at_exit` are refused by
  the envelope today, and a fixture checks that refusal. The fixture with a
  `rescue` and an `at_exit` hook, checking that the failure is not rescued and
  that the hook runs, is kept pending until the envelope admits them.
- The vendor patch carries its own check: a small program that calls the entry
  inside a `rescue` frame, with an `at_exit` hook, and observes that the frame
  is skipped, the hook runs, and the text and status are those of an uncaught
  raise.
- After the pin move, the Extended suites that depend on the vendor tree run
  through the documented build path, before this slice is merged.
- Refusals: a `wrap` or `promote` build, `**`, a shift and `abs` are still refused,
  with their diagnostics.
- The artifact gate passes, with the failure hook as the core object's only
  added undefined symbol.
- A sabotaged emitter must fail the suite. With checking off, `INT64_MAX + 1`
  wraps, and the suite must report that fixture.
- The suite runs on Debian x86_64 and macOS arm64 through the documented build
  path.
- Comparing the `--core` build with the hosted build of the same program, on
  the cases where both are defined, is recorded as a consistency check. Both
  builds come from one compiler, so this check is not independent. A
  comparison with CRuby is an oracle and runs only when the owner instructs it.

## Consequences

- Decision 0005's prohibition of trap insertion is lifted for arithmetic failure
  in this slice only, in the abort form defined above. Exception recovery is
  still not authorised.
- The README and the supported envelope stop saying "Arithmetic is refused"
  once the implementation and its validation land.
- The pin move is authorised by the owner for this record (2026-10-18). Other
  lanes see the new upstream too, so their suites are part of its validation.
- The abort entry is a local vendor patch. Offering it upstream is future work.
- A catchable failure would need a new record, either option 1 above or an
  upstream mechanism for core frames.

## Revision, 2026-10-18

Before any implementation landed, the owner revised two points of the text first
accepted that day:

- **The pin.** The first text kept `573aa44`. It refused a returned `INT64_MIN`
  as a pin-specific `RangeError`, and required no vendor patch.
- **The abort.** The first text required the abort to be built from Extended
  alone. The implementation found that impossible without changing the runtime,
  at that pin and at upstream `e1d92f1e1`: the `at_exit` runner, the printer and
  the frame stack are all `static`.

The owner chose to move the pin to upstream, and to add the abort entry as a
vendor patch.

## Implementation notes, 2026-10-19

These record what the implementation fixed where the text above left a
choice. None of them changes the contract.

- **The hook.** It is `void spc_core_fail(int32_t kind, int32_t op)`, declared
  `noreturn`. Kind 1 is overflow and kind 2 is a zero divisor. The numbers are
  defined once, in `tools/mlir/native/include/spinel-mlir/Scalar/Importer.h`.
  The emitter lowers the slice in a new `scalar::OverflowMode::Abort`.
- **The shim.** `spinel-core-emit` generates the shim as its own C file. The
  file includes only `<stdint.h>`. It maps the kind and operator to a class
  and a message, then calls `sp_abort_uncaught(cls, msg)`. A kind or operator
  it was not generated for traps.
- **The entry.** The vendor patch is `3c4984057`, "runtime: add
  sp_abort_uncaught, an uncaught report no frame can catch". It is the
  seventeenth commit of the pin `ad4bb8c42` (`docs/provenance.md`).
- **Unary minus.** Its message uses the operator's method name:
  `integer overflow in -@`.
- **The literal domain.** With the pin move, the slice also admits the
  literal `-9223372036854775808`, which the old pin reserved as nil.
- **The pending fixture.** The fixture with a `rescue` around the core call
  and an `at_exit` hook is still pending. The same fixture is checked to be
  refused by the envelope, as the Validation section requires.
- **Upstream's `INT64_MIN / -1`.** Upstream's answer for this pair is still
  not checked. The `RangeError` in the results table remains this record's
  choice.

Validation, with LLVM 23.1.1:

- `tests/native-core/arith.sh` checks every row of the results table, the
  refusals and the artifact gate. Its expectations are written by hand, and
  it is written in Ruby. It passed 50 with 0 failures and 1 pending on both
  Debian x86_64 and macOS arm64.
- A sabotaged emitter, with `OverflowMode::Abort` replaced by `Wrap`, fails
  the suite.
- The Extended suites that depend on the vendor tree ran after the pin move,
  as `docs/provenance.md` records under "Validation of the pin move".
- No CRuby comparison was run for this slice.
