# 0044: A freestanding helper that takes a buffer lent by its caller

- Date: 2026-11-14
- Status: Accepted by the owner on 2026-11-14, with the recommended choices:
  D1 (derived from the calls), L1 (always an address and length pair), B1
  with U1 (the helper always checks, and inherits the entry's `bounds:`), and
  beside 0041 stage 2, the second to land rebasing. The first implementer implements it.
  The direction is the owner's (2026-11-14, relayed by the bpf-mlir coordinator): unlock
  [0043](0043-mpc-instance-buffers.md)'s blocker A on the freestanding route.
  A call argument is limited to an i64 or f64 number today, so a buffer (an
  address and a length) cannot be passed to a helper, and that is the main
  limit to remove.
- Scope:
  - the freestanding route (`freestanding_def`, `spinel-fs-emit`) only;
  - a helper method, called from an entry or from another helper, that takes
    a buffer the entry was given and indexes it;
  - the diagnostic "is a boolean" given today for a buffer argument.

  Out of scope: the status lane and the native `--core` slice, which already
  pass a buffer to a helper ([0008](0008-doom-core-migration-plan.md)
  task 3, below); a buffer slice or a sub-range; a buffer made inside the
  kernel (0041 stage 2's data stack); a pin move or a vendor change; the
  typedump.

## Context

### What is refused, measured

The second implementer measured it on 2026-11-14, in notes kept outside the repository
(section 1), at the pin `c23d82a7c`. The entry is
`process(out, frames)`, declared `[[:f32_buf, :inout], :len]`.

- **A plain helper.** `def fill(buf, i); buf[i] = 0.5; 0; end`. Inference
  types it `fill: (Array[Float], Integer) -> Integer`, so `buf` is a
  `float_array`. `spinel-fs-emit` refuses it, rc 1:
  `'fill' parameter 0 'buf' is float_array`. The refusal is
  `Frontend/Scalar/Importer.cpp` (about line 480): an array is accepted only
  at a position where the **root's** `freestanding_def` says Buffer, and a
  helper has no declaration.
- **The same helper with its own declaration**,
  `freestanding_def :fill, params: [[:f32_buf, :inout], :len, :i32]`.
  Inference is the same. The refusal moves to the call, rc 1:
  `'process': argument of fill is a boolean; only Integer values are in the subset`.
  The source is `MlirGen.cpp`'s `needInt`/`needNumeric` (about lines 1170 and
  1185): a call argument must be an i64 or an f64. "boolean" is wrong here:
  the message assumes the only value that is not a number is an i1.

Upstream `020275b35` infers both files the same way, so the limit is
Extended's own, and lifting it needs no pin move.

### The buffer boundary today

`tools/freestanding/spinel/freestanding.rb` states it (E077 / P003):

- An entry takes `[:<elem>_buf, :in | :out | :inout]` followed by `:len`.
  The caller owns the storage; the kernel allocates nothing.
- The kernel may index the buffer, `b[i]` and `b[i] = v`, and nothing else.
- `b[i] = v` on an `:in` buffer does not compile, and the C prototype spells
  it `const`.
- `0 <= i < len` is a run-time check, trap code 4 (`bounds: :trap`, the
  default). A NULL buffer (5) and a negative length (6) trap at the entry.

### The CORE model

The status lane already lends buffers to helpers (decision 0008 task 3,
`ScalarBorrowedParam` in `Scalar/Importer.h`):

- The contract declares only the entry's buffers. The checker derives each
  helper's buffer parameters once, from the calls that reach it: the element
  type, read-only or not, and the entry buffer every call binds it to (its
  origin), when there is one.
- **The count is not a property of the helper.** It travels with the call,
  as the pointer does. A helper whose bound came from a name in its own body
  could move its own bound.
- A parameter whose every call binds the same entry buffer reads its pointer
  and bound from that buffer. Otherwise it is a pair of arguments.

The freestanding route has no eligibility checker, so the derivation would be
the importer's.

## Proposal

A helper parameter that every call binds to a buffer is a **lent buffer**:

1. **What the helper may do with it.** Exactly what an entry may do: index
   it, `b[i]` and `b[i] = v`, and pass it on as an argument to another helper
   (which then lends it further). Nothing else: no store of the buffer into a
   local, an element or a state slot, no `return` of it, no capture in a
   block other than 0041's literal blocks, which index it. Each is refused by
   name.
2. **How the call passes it.** As two values, the address and the length the
   caller has, in this order, in the parameter's place. The length is the
   caller's, never a value the helper computes.
3. **Bounds.** The helper checks `0 <= i < len` on every access, with the
   length it was passed, and traps with code 4, as the entry does. Under
   `bounds: :unchecked` on the entry, see question 4.
4. **Access mode.** A lent buffer carries its mode. An `:in` buffer stays
   read-only through every helper: a helper that stores into the parameter
   refuses a call that passes an `:in` buffer, naming the call, the helper and
   the store. The emitted C spells a read-only parameter `const`.
5. **Element type.** The parameter has one element type. A helper called with
   two different element types (an `f32` buffer at one call, an `f64` buffer
   at another) is refused, naming both calls.
6. **The diagnostic.** `needInt`/`needNumeric` name what the value is: a
   buffer, a boolean, or nil. A buffer argument that the helper does not take
   as a lent buffer gets a message that says so.

Nothing changes for the entry's boundary, the C prototype of an entry, the
traps 5 and 6, or a helper that takes only numbers.

## Choices for the owner

1. **How a helper says it takes a buffer.**
   - **D1 (recommended): derived from the calls.** A plain `def` needs no
     declaration. The importer derives each parameter from the calls that
     reach it, as the status lane's checker does: buffer or number, element
     type, read-only or not. A helper that also has its own `freestanding_def`
     (it is an entry too) must agree with what the calls pass, or it is
     refused.
   - D2: declared. A helper takes a buffer only if its own `freestanding_def`
     says so; a plain helper still refuses. Explicit, but a helper used only
     inside the kernel becomes an exported entry with a C prototype.
2. **How the length reaches the helper.**
   - **L1 (recommended): a pair, always.** Every lent buffer is the address
     and the length, two arguments. One rule, and a helper reached with two
     different buffers needs nothing more.
   - L2: as CORE does, an origin when every call binds the same entry buffer
     (no arguments, the helper reads the entry's pair), a pair otherwise.
     Fewer arguments, two code paths.
3. **The helper's own range check.**
   - **B1 (recommended): always in the callee.** Each access in the helper
     checks against the length it was passed (trap 4), whatever the caller
     checked.
   - B2: none in the helper when the caller's index is already checked. Not
     recommended: it needs a proof this route does not have.
4. **`bounds: :unchecked` on the entry.**
   - **U1 (recommended): the helper inherits the entry's setting.** A helper
     reached from entries with different settings checks.
   - U2: helpers always check.
5. **Order with 0041 stage 2** (the second implementer, the data stack, which also changes
   `MlirGen.cpp`): after 0041 stage 2 is merged, or beside it with the second
   to land rebasing. Recommended: beside it, the second rebases, as 0041 stage
   3 and 0042 stage 4 did today.

## Stages

One stage. Its predictions are committed to `0044-results.md` before the
implementation.

- **Question.** Does a helper index a buffer it was lent, with the caller's
  length, the entry's mode and the callee's own bounds check, on every target
  the freestanding lanes build?
- **Checks.**
  - The second implementer's two probes, now admitted: the plain helper (D1), and the
    declared one if it is an entry too.
  - A helper that lends the buffer on to a second helper.
  - A helper reached with two different buffers of the same element type,
    with their own lengths: each call's out-of-range index traps 4 at its own
    length, and the in-range calls write the hand-computed values.
  - Refusals, each by name: a store through an `:in` buffer in a helper; two
    element types; a buffer stored into a local or a state slot, returned, or
    passed where a number is expected; the corrected message.
  - Host, QEMU Cortex-M33 and RV32, wasm32 (the freestanding lanes' targets),
    and the FRDM-MCXN947 board lanes when the board is free.
  - The emitted C of a read-only lent parameter says `const`.
- **Not run.** CRuby or any other oracle.

After it lands, `feat/mpc-plugin-sdk` picks it up when it is rebased, and
0043's helper rule ("a helper that mentions a buffer is refused") can be
relaxed there.
