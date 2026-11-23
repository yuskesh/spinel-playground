# 0016: Call-duration mutable String borrowing through FFI

- Date: 2026-10-18
- Status: Accepted (owner, 2026-10-19). The native implementation is vendor
  patch `ad4bb8c42`; macOS Metal screenshots passed the raster visibility check
  (`docs/provenance.md`).
- Scope: a minimal vendor extension for DOOM's native raster seam. Existing
  `:str` and `:binstr` argument semantics remain unchanged.

## Problem

The pinned compiler publishes a mutable String as a copied read face when it
crosses an ordinary read-only parameter or `:str` FFI boundary. DOOM's raster
seam writes its framebuffer argument, so an accepted GPU frame can update a
copy instead of the screen. `:ptr` does not remove String publication, and
`--share-strings` still emits snapshots for this multi-buffer call.

## Contract

Add the explicit argument spec `:str_inout`, represented at the C boundary as
`char *`. It borrows the actual String's bytes only for the duration of one
synchronous call. It is an argument spec, not a return type. The caller passes
its byte count separately, as with existing FFI buffers.

C may read/write offsets `0...string.bytesize`, including embedded NUL bytes.
It must not resize/reallocate/free the buffer, change its length or terminator,
retain the address, reenter Ruby or allocate/collect through Spinel. The native
callee is trusted to honor its declared bounds, just as for `:buffer_inout`;
this spec does not make arbitrary C memory-safe.

The compiler must demand and root the original mutable String handle through
admitted local, instance-variable, accessor and method-parameter routes. It
must not manufacture a snapshot and lend that instead. Routes whose identity
cannot be preserved are rejected with a diagnostic naming `str_inout` and the
unsupported argument. Non-Strings and nil are rejected, not coerced to addresses.

A frozen String raises `FrozenError` before C is called (a statically known
frozen argument may instead be refused). Separate `dup`/snapshot values must
remain unchanged; aliases to the same admitted handle observe the C writes.
Before taking an address, the backing must be uniquely owned/writable: retain
an already-owned mutable payload, and detach an immutable/shared/COW backing
through the existing String ownership mechanisms. Do not copy the whole buffer
on every borrow of an already-owned mutable String.

All arguments are evaluated once in source order and rooted. Prepare all
borrowed handles before taking any byte addresses, since preparation of a later
argument may allocate and collect. Byte addresses are taken only after argument
preparation is complete. Keep the handles rooted until the call returns.

The initial slice refuses threaded builds, `blocking: true`, callback-taking
calls and programs declaring FFI callbacks when they use `:str_inout`. Callback
rejection covers declarations anywhere in the program, including unreachable
ones; it is not a reachability analysis of the borrowing call. Ruby signal
handlers and other asynchronous Ruby entry points are likewise refused. Its C
callee cannot run Ruby or Spinel GC, so collection or relocation cannot occur
while an address is borrowed. Supporting concurrent/reentrant borrowing later
requires an explicit locking/pinning contract; it is not silently enabled here.
Ordinary C/IREE allocations are not Spinel heap allocations.

After a normal return, publish the original length and encoding, clear cached
hash/ASCII/length-search answers affected by the written bytes, and retain the
NUL terminator at the original length. Arbitrary bytes do not change the
String's declared encoding; subsequent encoding validation must inspect them.
Return the C result unchanged. Native crashes, out-of-bounds writes and forbidden
reentry are callee contract violations, not catchable borrowed-buffer statuses.

## Initial slice boundaries

The first implementation deliberately refuses these unproved routes, with
`str_inout` and a reason in the diagnostic:

- Inherited fields, including writes from subclasses.
- Fields with an `attr_writer` or `attr_accessor` declaration.
- Conditional, compound or destructuring field stores: admitted field
  producers use ordinary `@ivar = value` assignments.
- Ordinary method-return aliases, container elements, captured locals
  requiring cells, block parameters,
  and producers whose original identity cannot be proved. A direct method
  returning a fresh expression such as ordinary one-format-argument
  `Array#pack` can be proved fresh; a
  copied ordinary return is never wrapped and silently lent as the original.
- Reflective instance-variable writes, `eval`/`class_eval`/`module_eval`, and
  `send`/`public_send`/`__send__` anywhere in a borrowing program.
- Threads, asynchronous Ruby entry (including signal handlers), blocking calls,
  and any FFI callback declaration, including unreachable declarations.

The argument proof follows emitted borrowing calls; unused bodies do not need
invented argument types. Callback declarations and reflective-operation
restrictions remain program-wide.

Refusal controls cover the named boundary groups alongside successful native
write controls. These restrictions can be widened only with a corresponding
identity/lifetime proof; they do not enable `--share-strings` implicitly.

## Integration and limits

Use `:str_inout` for both raster screen and zone-window arguments. The zone is
read-only in this callee, but lending its mutable storage avoids a read snapshot;
the seam does not exercise its write capability. WAD and resident immutable
inputs retain their existing specs. Document the framebuffer's actual writable
C parameter. Do not enable `--share-strings` for the whole game.

The vendor change is the nineteenth local patch above `6aa5f6395`, developed in
an isolated clone. Keep it limited to spec validation, handle-demand propagation,
ordered argument conversion and String borrow/publication helpers. A failure to
prove an identity/lifetime route is a refusal, not permission to use a side
channel or an integer cast. This does not repair every existing default-mode
String alias limitation or add a general ownership IR.

## Acceptance

- Fresh and reused mutable buffers expose C writes to Ruby; embedded NUL and
  empty buffers keep their length, and repeated borrows do not copy owned data.
- Same-handle aliases observe writes; separate duplicates/snapshots do not.
- Frozen/non-String/nil inputs and unsupported concurrency/callback modes refuse
  before invoking C. Diagnostics name the new contract; legacy `:str` is unchanged.
- Argument evaluation is once/in order, and preparation roots survive allocations
  or GC before entry. Hash/ASCII/encoding observations after writing are current.
- Generated DOOM C has no `sp_strbuf_read`/`sp_strbuf_read_pub` on the borrowed
  screen/zone paths. Mac Metal screenshots pass the raster visibility check
  (selected DEMO1 tics, at least 50% non-black RGB in the 3D viewport), with GPU
  frame/reject checks retained and no CPU rendering comparison.
- Tests and new maintained tooling use Ruby or sh; vendor compatibility evidence
  and the patch provenance are recorded before moving the dependency pin.
