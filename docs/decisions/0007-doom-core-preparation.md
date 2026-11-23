# 0007: Prepare allocation-free CORE computation for DOOM

- Date: 2026-09-11
- Status: Accepted
- Scope: Stage 1 of the route from hosted DOOM to CORE DOOM and then freestanding DOOM. This defines a new buffer boundary and failure ABI; acceptance does not mean implementation is complete.

Approval record: on 2026-09-11 the owner explicitly approved this design after
reviewing its safety improvements, deliberately narrower initial feature set,
i64 word transport and unmeasured performance. This accepts the contracts below,
including the later review refinements, and authorizes Debian implementation.
References to a proposal/recommendation below describe the design rationale;
they are not additional approval gates. Vendor changes and pin movements remain
separate decisions. Follow the [implementation plan](0007-doom-core-preparation-plan.md).

## Context

The owner requested this sequence: prepare CORE for DOOM, implement CORE DOOM,
prepare the freestanding integration, then run freestanding DOOM. Implementation
belongs to Debian; macOS provides review and native validation. The design may
be merged before implementation. The subsequent explicit approval recorded above settles the new ABI below;
implementation may now proceed within it.

The current [native CORE boundary](0005-native-core-executable.md) admits a
small ordinary-Ruby scalar subset. DOOM additionally needs arithmetic, loops,
indexed mutable state, read-only resources and a much larger direct call graph.
Its Ruby classes, Strings and Arrays are not allocation-free merely because
they were allocated before a frame. CORE must not reach their Spinel runtime
representation or helpers.

[Source survey](../core/doom-preparation-survey.md) records current code and
predecessor evidence. Existing freestanding lowering supplies useful mechanisms,
but its declarations, trap policy and positional buffer lengths do not establish
a safe Full/CORE boundary. Decision 0001 explicitly left buffers undecided.

## Options

1. Import the predecessor's freestanding surface wholesale. Shorter initial
   implementation, but inherits trap/wrap policy and caller-managed raw pointers;
   does not connect ordinary hosted objects safely.
2. Expand inferred ordinary Ruby CORE to cover the existing DOOM unchanged.
   Preserves the source, but entails object representation, allocation, dispatch
   and lifetime work far beyond this stage. Inference of `Integer` cannot supply
   foreign buffer capacity or ownership.
3. Add an explicit, checked numeric/buffer entry contract while preserving the
   ordinary scalar route. Reuse compatible lowering mechanisms behind it. Move
   DOOM computation into methods over caller-owned storage in stage 2.

**Recommend option 3.** It makes the memory boundary reusable beyond DOOM and
leaves platform support separate. It costs a new explicit interface and a later
DOOM data-layout refactor; those costs are visible rather than implicit.

## Decision

### Four stages and their boundaries

| stage | delivered behavior | completion evidence |
|---|---|---|
| 1: CORE preparation | native numeric/buffer kernels callable from Full, with checked closure and generated boundary | scalar, raster and fixed-capacity state slices below, on Debian and macOS |
| 2: CORE DOOM | game tick and CPU rendering execute in CORE; Full supplies setup, storage, input, clock and display | full demo state/frame comparison and interactive acceptance |
| 3: freestanding preparation | target-specific startup, memory provision and platform ABI around the same computation | target build, ABI and dependency checks plus target harness |
| 4: freestanding DOOM | that integration runs DOOM on a separately selected target | independent replay and target input/display checks |

Stage 1 does not claim the complete game is covered. Stage 2 may discover missing
forms; each must receive a fixture and a contract review when semantics change.
Neither stage 1 nor stage 2 makes the hosted executable GC-free. CORE itself
allocates nothing. Full may allocate, load WADs and retain the normal runtime.

### Numeric meaning and source selection

Keep the existing `--core` scalar behavior and ABI unchanged. Introduce an
opt-in contract file for buffer-capable entry points, versioned independently
of the analysis dump. It names the source method, each parameter by name, its
scalar domain or buffer element type and access mode, and the result type.
Unknown fields, missing parameters, duplicate names, unsupported versions and
unresolved methods are errors. Do not add a Ruby parser, synthetic callers or a
new general-purpose IR. A declaration supplies entry facts; the checker must
validate every use and reachable callee against them.

Version 1 selects uniquely named, unconditional top-level methods. Qualified
module/singleton methods remain unsupported. Extract complete DOOM helpers into
acceptance fixtures with recorded original paths and explicit name/constant
adaptations; compare them against the original Full helpers. Do not extract an
unguarded division from `Fixed.div`: its zero-divisor guard returns saturation,
and that saturation is a successful result, not an arithmetic failure.

The initial numerical domain is signed 64-bit mathematical integers with
explicit entry subsets `i32`, `u32`, and `i64`. Buffer elements are `u8`, `i32`,
`u32`, or `i64`. Native entry values have no nil sentinel. The hosted bridge
checks conversion separately and must never reinterpret boxed values or nil as
integers. Boolean intermediates are supported; floats, nullable values and
boxed unions are outside this version.

Successful operations agree with Ruby: floor division and divisor-signed
remainder, arithmetic right shift, comparisons, `&`, `|`, `^`, `~`, `abs`, and explicit
masking. Parenthesized expressions preserve evaluation order. Integer exponentiation
(`**`) is refused in this version. `+`, `-`, `*`, unary negation, left shift, `/` and `%` require checked
lowering or a proven safe range. Shift counts are restricted to 0..63 at this
boundary. Results outside signed i64, zero divisors and out-of-domain shifts
return failure. `abs(INT64_MIN)` also fails; `abs(INT32_MIN)` succeeds with
2147483648 in the i64 domain. Ruby reverses the direction of negative shifts;
this boundary deliberately refuses those inputs instead. Check only operations
on the executed control-flow path, not an untaken division or saturation branch.
Do not silently wrap, invoke BigInt, introduce C signed overflow,
or replace Ruby division with C truncation. An explicit Ruby mask such as
`v & 0xffffffff` still means that operation, not a global wrap switch. DOOM's
fixed-point helpers widen before multiplication and explicitly normalize to i32;
these helpers are the initial arithmetic acceptance workload.

The admission rules include `while`, local assignment, conditionals, early
return and direct helper calls. Only a closed, statically resolved call graph
is accepted. Recursive cycles, blocks, dynamic dispatch and platform calls are
refused initially. Mutable state moves to indexed buffers; Ruby object/ivar
access is not admitted by attaching a CORE label to it. Literal immutable tables
may be emitted as read-only data after size and element validation; arbitrary
constant initialization does not run in CORE. Scalar integer constants are also
admitted when a single unconditional literal definition in the checked source
snapshot resolves the name. Reject reassignment, dynamic lookup and computed
initializers in version 1; do not evaluate Ruby initialization to resolve them.

### Buffer ownership, lifetime and aliasing

Full owns separately allocated native storage. CORE receives a synchronous
borrow, never ownership. The first bridge copies from/to Ruby values and checks
element conversion; it does not borrow the internal address of a Ruby String
or Array. Native storage may persist across calls under Full ownership. No
CORE allocation, resize, free, escape, retained pointer or callback is allowed.
The caller must keep storage alive for the entire call; a raw foreign pointer's
actual capacity cannot be established by the compiler.

Each buffer has its own pointer and `uint64_t` element count in the generated
C boundary, and an explicit `in` or `inout` mode. Avoid the predecessor's
positional shared `:len` binding. Do not use `out` in version 1: buffers must be
initialized, and partial writes on failure make write-only promises misleading.
Zero length permits NULL; nonzero length requires non-NULL and proper alignment.
Entry validation checks count-times-element-size and address-range overflow
against the target address width before pointer arithmetic.

Two read-only buffers may overlap, including two arguments for identical storage. Any overlap involving an `inout` buffer is
rejected at entry, including two names for the same storage. A kernel needing
in-place neighboring reads, such as fuzz, uses one `inout` buffer and explicit
indices. Never attach `noalias` without establishing this contract. Subviews are
deferred: offsets are explicit integer arguments and accesses are checked
against the complete buffer. Every load/store checks `0 <= index < count` unless
that condition is proven, including the arithmetic that computes the index.
Reject `bounds: unchecked` and equivalent opt-outs. Loads zero-extend u8/u32
and sign-extend i32 into i64. Stores range-check before writing u8/i32/u32;
there is no implicit truncation. A caller wanting masked values must compute
the mask explicitly. An out-of-range store returns ARITHMETIC without executing
that store; earlier writes retain the partial-write rules below.

### Failure ABI

Recommend a generated, versioned C entry returning `int32_t` status, with scalar
results written through a separate checked result pointer. Statuses are
`0 OK`, `1 ARGUMENT`, `2 ARITHMETIC`, `3 BOUNDS`, and `4 CAPACITY`.
These numbers are new ABI values, not predecessor trap codes. Use named failure
categories and an explicit mapping; never forward a numeric trap code. Narrowing
of computed values at a store or return is ARITHMETIC; an invalid entry scalar
is ARGUMENT. Test these separately from BOUNDS and CAPACITY. Result-type narrowing
is checked before result publication.
Result storage must be valid, aligned and disjoint from all buffer ranges.
Internal calls propagate failure without runtime calls. No trap hook, exception
unwind or retry through Full is inserted. This is an explicit checked-entry
contract, not ordinary Ruby exception behavior.

All descriptor validation occurs before any kernel write. An entry-validation
failure leaves buffers and result untouched. Once execution begins, failure
may leave an already-written prefix/state change; no rollback is promised.
The scalar result is published only on success. The Full adapter reports the
status after returning from CORE and discards or reinitializes failed working
state before reuse. Allocation failure in the adapter is a Full-side failure
before entry, not evidence of a CORE allocation.

Capacity-limited state operations use caller-provided slots and indices. Full
allocates the pool; CORE may update its occupancy but cannot grow it. Exhaustion
returns CAPACITY. Application invariants such as atomic insertion must be
established by checking capacity before that operation mutates links; the ABI
does not provide a general transaction mechanism.

### Implementation boundaries and dependency policy

Reuse the contract reader, scalar importer, checked arithmetic mechanisms and
buffer lowering only after examining their assumptions. Separate CORE failure
emission from hosted raises and freestanding trap hooks. Reuse overflow
intrinsics and their result/overflow pair, not the hosted Raise arm: its nil
sentinel tests and `sp_raise_*` calls violate this boundary. The freestanding
trap arm also calls an external hook and is not reusable as the failure path.
Provide a distinct status-propagation path with no nil sentinel, including at
INT64_MIN. The existing signed i32 positional `:len` must not be reused as the
new per-buffer u64 count or narrowed during validation. Keep tier validation,
target layout and platform permissions separate; do not fork a second universal
frontend or route hosted compilation through MLIR.

Generate the header, adapter and object from the same validated contract and
source snapshot, recording their digests and target layout. Verify producer and
consumer signatures before linking. The object gate initially allows no undefined
symbols, dynamic initializers, writable globals or platform calls. If lowering
introduces a support routine, refuse it and review that exact dependency; no
`sp_*`, compiler-runtime or libc prefix allowances. Static body/closure checks
remain necessary alongside artifact inspection. A finite acyclic call graph has
a finite maximum call depth, but that does not establish a target stack-byte
budget. Stage 1 does not certify such a budget; target stack analysis remains
stage 3 work. Dynamic stack allocation is not admitted.

Use the existing pinned vendor. A required vendor change or pin movement needs
a separate minimal proposal and compatibility evidence. No predecessor checkout
is a build dependency. Imported components need original revision/path, local
differences, notices and executable tests.

## Validation and stage-1 exit

Three end-to-end capabilities are required, not just compiler feature tests:

1. Fixed-point arithmetic and angle normalization, including negative division,
   boundary products, i32 limits and explicit u32 masks, checked against CRuby.
2. Wall column, span and fuzz-style neighbor access using real DOOM resource
   layouts and deterministic small fixtures. Preserve schedule/read-write order;
   compare all framebuffer bytes with the existing Full implementation.
3. Fixed-capacity state slots and linked indices, exercising insertion, removal,
   reuse and exhaustion with a reference model and invalid-index controls.

Each must run through the generated Full adapter and standalone CORE object.
A direct C harness also tests the full native scalar domains, including values
that cannot use the existing sentinel-bearing hosted scalar ABI. Use canaries
and sanitizers in the harness where supported; neither substitutes for the
specified bounds and ownership checks.

Reject allocation in a reachable helper, callback/escape, read-only writes,
overlapping mutable buffers, invalid lengths/alignment, arithmetic overflow,
zero division, invalid shifts, buffer underflow/overflow and pool exhaustion.
Include controls that otherwise link and produce plausible output. Check partial
write behavior deliberately. Alter an object/header/contract and require refusal
before execution. Retain existing scalar CORE and hosted DOOM regressions.

Debian implements and records commands, revision, toolchain and real execution
IDs. macOS independently builds and runs the new boundary tests. A stage is not
complete on the strength of predecessor results or a single generator comparing
against itself. Performance is measured separately after correctness; copying
cost is reported, not hidden in kernel-only timings.

## Consequences and approval

This record recommends a recoverable checked ABI, explicit borrowed native
buffers, and i64 operations whose successful results preserve Ruby semantics.
Those are the concrete decisions accepted by the owner for implementation. The
existing scalar CORE and freestanding declarations are not superseded.

Freestanding reuse benefits from the absence of GC and platform calls, but still
requires a target decision, startup/linker work, memory budgets, stack analysis,
I/O adapters and target validation. None is claimed by a native object test.

## Source failure and explicit Full adapter

Review after `93bcd93` identified two missing interfaces. The following completes
the accepted direction; both are covered by the owner's approval of this record,
not implementation claims.

### Application-requested failure

Use the contract-only intrinsic `core_fail(:capacity)`, which has no successful
return value and lowers directly to status propagation. Recognize it only in the
new entry closure; reject a conflicting user definition or any other argument.
It neither reserves an integer result nor admits Ruby `raise`. A separate
reference harness models it as an exception and compares the resulting status;
it is not an intrinsic provided by unmodified CRuby. Compiler-generated failures
and this explicit request use the same internal failure categories.

### Storage and calls visible to Full

Generate an explicit Full FFI adapter, leaving the current scalar selection seam
unchanged. The adapter owns aligned native allocations and a registry mapping
positive, monotonically issued IDs to live typed storage. IDs are not addresses
and are never reused during the process lifetime. Exhausting the ID space fails
allocation; it must not wrap. Zero is reserved for allocation failure. IDs remain
within the positive signed i32 range so their transport does not depend on the
hosted nil sentinel.

Expose operations through a generated Ruby module for each contract:

| operation | Full-visible behavior |
|---|---|
| allocate(element type, count) | positive storage ID, or zero on failure; storage is initialized |
| store(id, index, value) | status; checked conversion and write, no unchecked offset arithmetic |
| load(id, index) | status and value on success |
| store_i64_words(id, index, low, high) | status; each word is an unsigned 32-bit integer |
| load_i64_words(id, index, out_id, low_index, high_index) | status; write both words to caller-specified u32 storage |
| invoke(named storage IDs and scalar arguments, result_id) | status; publish scalar result to element zero of caller-specified typed storage on success |
| release(id) | status; free live storage and invalidate its registry entry |

The ordinary `load`/`store` operations accept only u8/i32/u32 storage. i64 storage
requires the words operations; using the wrong operation returns ARGUMENT.
`load` is a Ruby wrapper over one scalar-returning C operation: return an i64 in
0..4294967295 for successful data, or the negative status on failure. Encode an
i32 value as its unsigned two's-complement 32-bit value; the Ruby wrapper decodes
values >= 2147483648 by subtracting 4294967296 for that element type. Thus neither
success nor failure uses INT64_MIN, and validation plus access is one operation.
The wrapper may construct its status/value pair in Full. No separate validation
call followed by an unchecked read is allowed.

`load_i64_words` validates the source and both distinct output indices before
writing either word. Equal output indices return ARGUMENT without writes; both
indices must also be in range. Its destination must be live u32 storage disjoint from the
source. The entire transfer occurs under one lock; on failure both output cells
are unchanged. Subsequent ordinary loads can retrieve the words. The caller owns
that output storage and must not let another thread mutate/release it between
those reads; individual operations are synchronized, a sequence of Ruby calls is
not a transaction. No shared last-error or implicit result slot is used.

`invoke` requires result storage of the declared result element type with at
least one element, disjoint from every input/inout range. The adapter rejects a
`result_id` equal to any participating buffer ID with ARGUMENT before invocation,
including a zero-length participant. It writes element zero
only on success; remaining elements and the previous result on failure are
unchanged. This ID is an ordinary caller allocation, not an implicit per-contract
slot. i64 results are retrieved through the words operation.

A C-side mutex owned by the Full adapter serializes all registry/helper operations,
including the entire CORE invocation and release. No callback into Full occurs
while it is held. Failure to initialize synchronization prevents adapter startup;
there is no unlocked fallback. Platform synchronization and allocation dependencies
belong to the separately built Full adapter, not the CORE object. The zero-undefined
symbol gate applies to the CORE object only. Validate that the adapter cannot be
mistaken for that object in packaging. Native direct callers retain responsibility
for synchronizing their own memory.

An allocation of zero elements returns a live positive ID with count zero and
NULL data, subject to registry allocation success. It is releasable normally;
loads/stores fail and native invocation passes the zero-length descriptor.
Storage must be reused across ticks; ID non-reuse is a finite process budget,
not permission to allocate per column/job. Element copies are setup/inspection
operations, not the per-pixel execution path. CORE operates on resident storage.

Validate every ID, element type, index and conversion before access. Invalid,
stale and double-released IDs return ARGUMENT, as do invalid copy indices at the
adapter boundary; kernel indexing failures remain BOUNDS. The registry prevents
forged integers from becoming addresses, but is not a security boundary: a caller
that passes another live ID still refers to that storage. The generated wrapper
checks expected types and the application remains responsible for passing the
intended buffer. No promise of unforgeable Ruby capabilities is made.

The adapter does not use GC-managed addresses or depend on finalizers. Full must
release allocations explicitly; a leak is a Full-side leak. On a failed CORE
call, mark mutable participating kernel storage invalid for every operation except
release; it must be released and recreated. The disjoint result storage is not
poisoned, since failed invocation leaves its prior value unchanged. This enforces the earlier partial-write rule instead of
silently reusing damaged state. Read-only inputs remain usable. Direct C callers
retain the caller obligations of the native ABI.

### Full i64 transport

The native CORE ABI retains the entire signed i64 domain. For Full-facing i64
arguments, elements and results, use low/high unsigned 32-bit words as the
canonical lossless representation. Words are numeric values, so this wire contract
is independent of native byte order. Bit 31 of high is the i64 sign bit; combine
and split in C with defined unsigned operations. Do not reconstruct INT64_MIN
as a hosted Ruby Integer or pass it through an `:int64` return. Ordinary i32/u32
values remain ordinary Ruby integers on the two supported 64-bit native hosts.
Raw native computation results may stay in adapter storage between calls.

This choice trades convenience for lossless transport on the current pin. A
future Ruby-facing full-domain Integer result needs a separate conversion design;
it is not promised by this version. The direct C harness exercises full-domain
arithmetic independently of this transport.

### Evidence and required adapter validation

The pin contains `ffi_buffer`, `ffi_func` and width-specific accessors. Debian's
scratch investigation reported aligned allocation, indexed C helper access,
invocation and release through `ffi_func` without vendor changes. It also
reported INT64_MIN returning as nil through `:int64`, and a separate literal
construction discrepancy. These are scoped observations, not a validated new
registry adapter. Preserve exact fixtures and rerun them during implementation.

Source inspection confirms accessor offsets are declaration-time constants;
`analyze_scope.c` clamps an unrecognized offset to zero. Do not use those
accessors for runtime indexed copies. Generate bounds-checked C helper operations
instead. Static module `ffi_buffer` storage does not provide per-instance
ownership, so it is not the proposed persistent storage mechanism. `:int_array`
is not used to establish lifetime or mutable access in this version.

Before calling the adapter complete, exercise invalid/stale IDs, double release,
wrong element types, exhausted ID allocation, copying boundaries, failed invoke
invalidation, serialization, and word round-trips including INT64_MIN and
INT64_MAX. Compile the generated wrapper on the pinned compiler on both native
hosts. If the explicit adapter cannot implement this contract, present the exact
required vendor change for separate approval; do not silently modify the seam.

The following clarifications apply to the proposed contract:

- Invalid descriptors (NULL with nonzero length, alignment, range overflow or
  forbidden overlap) return ARGUMENT before writes.
- `INT64_MIN / -1` returns ARITHMETIC. `INT64_MIN % -1` produces Ruby's zero;
  lowering must special-case it rather than execute an invalid signed remainder
  instruction. Rejecting every paired remainder would unnecessarily shrink the
  admitted successful domain.
- Loop optimizations may introduce `memset` or `memcpy`; whether they do is
  pipeline- and kernel-dependent. Version 1 retains zero undefined symbols.
  Disable transformations that introduce such calls for this compilation path,
  and inspect the final object at the selected optimization level. A compiler
  option alone is not proof. Add clear/copy loop controls. Do not add libc
  allowances merely to make the first raster test link. On later 32-bit targets,
  i64 arithmetic may also need compiler support routines; that is stage 3 target
  policy work, not permission granted here.
- This new boundary proposes the status-return alternative described in 0001.
  It does not change the imported `freestanding_def` trap behavior or the 0005
  ordinary scalar ABI.
- Stage 2 requires a real source refactor: extract top-level buffer-oriented
  kernels and make the Full implementation call them through its reference path
  or generated adapter. Prefer one maintained computational source over a second
  independently edited CORE copy. Keep the pre-refactor Full behavior as a fixed
  test reference. Record GPL-derived modifications and verify state/frame bytes;
  this is not transparent compilation of the existing object-oriented DOOM.
