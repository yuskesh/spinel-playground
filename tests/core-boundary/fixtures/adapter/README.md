# Operation fixtures for the Full adapter

Written **before** the adapter exists, so the expected answers are fixed
independently of whatever it turns out to do.

`operations.tsv` is the claim: for each case, the operation, the situation the
harness builds first, the arguments, the answer, and what must be observable
afterwards. Written from decision 0007's operation table and the rules around
it.

**Nothing here is a Ruby-level case.** The registry, the lock and the
operations are C, and that is where their behaviour is decided; the generated
Ruby module is a separate lane once it exists. Writing Ruby cases now would be
asserting the shape of something unwritten.

The cases that carry the most weight:

- an allocation of **zero elements** is a live positive ID with NULL data:
  releasable, but loads and stores on it fail;
- IDs ascend and are never reused, and **exhausting the space fails allocation
  rather than wrapping** — exercised through a controlled test limit, since the
  real budget is an i32's worth;
- `load` answers with an encoded value or a **negative status**, so neither
  success nor failure uses INT64_MIN and validation and access are one
  operation. An `i32` element arrives as its unsigned 32-bit pattern and the
  wrapper decodes it;
- the ordinary `load`/`store` refuse `i64` storage, and the words operations
  refuse everything else: using the wrong operation is ARGUMENT, not a
  reinterpretation;
- `load_i64_words` validates **both** output indices before writing **either**
  word — equal indices, an out-of-range index, a destination that is not `u32`,
  and a destination aliasing the source are each ARGUMENT with neither cell
  touched;
- `invoke` refuses a result that aliases any participant, is the wrong element
  type, or has zero length — **before** invoking, with the previous result
  unchanged;
- a failed `invoke` **poisons the mutable participants**: every operation on
  them except `release` is ARGUMENT afterwards. The result storage is not
  poisoned, because a failed invocation left its prior value alone;
- an adapter index failure is ARGUMENT while a kernel index failure is BOUNDS,
  and the two are separate cases rather than one.

**A value the caller supplied that the element type cannot hold is ARGUMENT.**
I had recorded it as ARITHMETIC, reasoning from the kernel's narrowing rule;
that was wrong and Mac's review said so. The decision puts an invalid entry
scalar under ARGUMENT and requires the adapter to validate every conversion
before access, and ARITHMETIC is for a value the **kernel computed** and could
not store. The two are different questions and the cases keep them apart: a
`store` of 256 into `u8` and of -1, and a word argument that is negative or
above 4294967295, are each ARGUMENT with nothing written.

Three contracts appear here, because one cannot answer every case. `sum_u8` has
no mutable participant and a loop the registry's count bounds, so it can
neither fail on bounds nor be poisoned. `store_at` has an `inout` buffer and an
index the caller chooses. And `sum_i64` is the only shape in which an `invoke`
whose result id equals a participant id differs from that participant in
**nothing but the id** — with a `u8` input the element-type check refuses it
first and the identity rule is never reached, so that case was measuring the
wrong thing.
