# Descriptor, access and refusal fixtures for the checked buffer boundary

Written **before** the buffer lowering exists, so the expected answers are
fixed independently of whatever that lowering turns out to do.

`descriptors.tsv` is the claim: for each case, how the **call** is built
(`shape`), what the buffers hold going in, the status, the result on success,
and what the `inout` buffer must hold afterwards. The shapes are the part that
cannot be written in Ruby — a NULL pointer, a misaligned one, two arguments
naming one storage, a count whose byte size leaves the address space — and they
are why this table is not a second `cases.tsv`.

CRuby is **not** the oracle here, and saying why is the point. A Ruby Array is
not this boundary's buffer: a negative index counts from the end, a store past
the end grows the array, and an element has no width. Each of those is a case
below with a *status* rather than a value — `bounds`, `bounds`, `arithmetic` —
and the divergence is deliberate. Where the semantics do coincide (an in-range
non-negative index, a value that fits the element type) the successful values
are ordinary arithmetic and are stated directly.

The cases that carry the most weight:

- a NULL pointer with count zero, which is **admitted**, against a NULL pointer
  with a nonzero count, which is not;
- two read-only buffers over identical storage, which is **admitted**, against
  any overlap involving the `inout` buffer, which is not — including two names
  for the same storage and two ranges that merely intersect;
- a result pointer inside a buffer's range, which is refused like any other bad
  descriptor;
- `u8` and `u32` loads zero-extending and `i32` loads sign-extending, so 255 is
  255, 4294967295 is 4294967295, and -1 is -1; decision 0018's `i8`, `u16` and
  `i16` the same way, at both ends of each range;
- a store of 256 or -1 into a `u8` buffer: `arithmetic`, and **that store does
  not execute** — and one past either end of `i8`, `u16` and `i16` the same;
- `partial_store`, which writes every element and then makes one more store
  that may fail. An entry failure leaves the buffer untouched; this one happens
  after execution has begun, so the written prefix stays and no rollback is
  promised.

`refuse/` holds sources that must not compile at all: a store into a buffer the
contract declares `in`, and `[]` on something that is not a declared buffer
parameter.
