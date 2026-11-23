# Dependency provenance

Every tracked file is listed by [`imports.tsv`](imports.tsv) under exactly one row, with its import batch (a section below) and the licence the record states; `tools/provenance/check-imports.rb` fails on a file no row covers, and every import adds its rows in the same commit.

## Project licence (2026-11-20)

The owner chose the project licence on 2026-11-20: Apache-2.0 WITH LLVM-exception, in [`LICENSE`](../LICENSE), with [`NOTICE`](../NOTICE) ([decision 0048](decisions/0048-project-licence.md)). It covers the files written here (`project` in `imports.tsv`) and, by the owner's statement of the same day, the files ported from the owner's earlier repositories, which stated no licence (`project-ported`; `none-stated` before). Files with their own SPDX line keep that licence. The files written here inside the DOOM tree (`examples/doom`), which derive from or drive its GPL-2.0 code, are GPL-2.0. Where a section below says a licence is undecided or must be settled before publication, it records the state at the time; this section settles it.

## Ghostty, linked by the terminal example (2026-11-09)

`examples/ghostty-terminal` is written here. It links libghostty-vt from Ghostty
commit `711702d572cfef2897b898d7147050fc6808f6e6`, built with Zig 0.17.0. Ghostty
is not imported: the suite takes a built checkout through `GHOSTTY_DIR`.
`examples/ghostty-terminal/keys.rb` is generated from Ghostty's
`include/ghostty/vt/key/event.h`. License: MIT, "Copyright (c) 2024 Mitchell
Hashimoto, Ghostty contributors"; a distributed `shell.wasm` must carry that
notice.

## Core source eligibility checker (2026-09-10)

The new `spinel-core-check` implementation is separate from exported core-object
generation. It reuses the existing imported contract reader and model; no
additional predecessor component or runtime patch was imported. The method
binding follows the existing scalar importer's scope-based contract, while the
new conservative effect rules live in `lib/Core/Eligibility.cpp` under
`tools/mlir/native`. The CLI lives in `tools/spinel-core-check/main.cpp` there.
Existing attribution for the contract reader remains applicable. This addition
does not resolve the undecided project-wide licence (settled on 2026-11-20: Project licence, above).

Base: Extended `9913c3a70e1ec05f209bb7a3d16a45226661bf3b`; Spinel remains at
`5bc45ec19a372c6f4da29485a7ce35c81b9751cc`. No vendor source, exported ABI,
integer policy or existing freestanding emitter source was changed.

### Local implementation evidence

The checker was built and exercised on macOS arm64 with Homebrew LLVM/Clang
22.1.8. This is auxiliary evidence, **not** a Debian/LLVM 23.1.1 result.
The checkout contained its own initialized pinned vendor and built dependencies;
no sibling predecessor checkout or prebuilt predecessor artifact was used.

Commands, from the isolated checkout root:

```sh
git submodule update --init --recursive
PATH=/opt/homebrew/opt/ruby/bin:$PATH make -C vendor/spinel deps
PATH=/opt/homebrew/opt/ruby/bin:$PATH CC=/opt/homebrew/opt/llvm/bin/clang tools/contract/build.sh
LLVM_PREFIX=/opt/homebrew/opt/llvm tools/mlir/native/build.sh
python3 tests/core-eligibility/run.py
```

All commands exited 0. The acceptance suite passed 32 tests. It checks admission,
helper closure and diagnostics, unobserved branches, heap/state refusals,
unproved arithmetic, missing/nullable types, recursion, ambiguous definitions,
malformed reader output and source-level primitive rebinding. It includes
required-field corruption in both selected and unrelated top-level definitions.
Existing imported sources emitted compiler warnings during the native build;
this is not recorded as a warning-free build.

Targeted mutations, restored before the final suite:

- Removing callee traversal failed both the helper coverage and allocating-helper
  checks (2 failures).
- Removing the literal heap-node refusal failed the allocating-helper reason
  check (1 failure).
- Before the top-level structural gate was added, primitive rebinding through
  `prepend`, an unexamined setup helper, and top-level assignment controls each
  exposed a false `CHECKED` result. All three now fail closed.

One producer limitation was encountered and retained as a fail-closed test:
literal `send` rewrites can leave type-face nodes absent from the AST. The
existing contract reader reports `dangling-reference`, and the new driver exits
2 rather than treating that source as eligible.

The primary Debian/LLVM 23.1.1 run remains outstanding. The existing core suite
uses an x86_64 Linux profile and links/runs its artifacts, so it was not run as a
macOS substitute. The GC/arena suite and full upstream suite were not rerun for
this source-analysis-only addition. The native build rebuilt the existing
`spinel-fs-emit` and `spinel-fs-check` targets successfully; that is build
compatibility evidence, not their runtime acceptance result.

See [Core source eligibility](../tools/core/README.md) for exact input limits,
report meanings and usage. `CHECKED` is a source-analysis conclusion only;
neither an emitted-object proof nor completion of the core/full milestone is
claimed by this section.

## Spinel baseline

The current pin is `4e0a59bd999e614bd8b2ece72ec2b8d0cbbc5522`, the fork's
`sync/upstream-f8ff0193`: the fork's stack replayed in one step onto
upstream `f8ff01939`, 23 commits above it; see "Upstream synchronisation,
2026-11-14" below. Upstream `f8ff01939` contains the two upstream commits
the previous pin `baddd25a9` backported (`--gc=none` and the Float-in-while
fix), so neither is in the stack now.

This baseline records the adoption through 2026-09-23. The local integration
update is recorded under "Upstream synchronisation, 2026-10-18" below.

- Local path: `vendor/spinel` (Git submodule; the entire upstream source tree).
- Fetch source: https://github.com/yuskesh/spinel.git
- Upstream: https://github.com/matz/spinel
- Pinned revision: `573aa44c689830b60dc6f928282d08c9bfc9044d`, the tip of the
  fork's `extended/patch1-extern-methods-6d69d010`: one commit, Patch 1
  (`SPINEL_EXTERN_METHODS`), on `6d69d010`; see "Patch 1:
  SPINEL_EXTERN_METHODS, 2026-09-23" below. `6d69d010` is the tip of the
  fork's `rebase/core-input-ledger-8279058d`: the fourteen-commit patch
  stack rebased onto upstream master `8279058d`, plus one commit re-recording
  the arena suite's declared transitions; see "Upstream
  synchronisation, 2026-09-21" below.
- Master synchronization: `8279058d0deb5b7642d4152e3d2d8634b5f5972b`,
  2026-09-21. The previous sync point was
  `d9eb84566eac0fce8b50cd4096e8594d6f303643`, 2026-09-09.
- Adoption date: 2026-09-09; resynchronized 2026-09-21.
- Origin: the fork's master was fast-forwarded by 1,121 commits and verified
  identical to upstream master at the 2026-09-09 synchronization, and by a
  further 485 commits at the 2026-09-21 one.
- Local source changes: none in this repository. One predecessor fork patch is
  imported into the fork: Patch 1, below.
- License: MIT; copyright Yukihiro Matsumoto. The original notice remains in `vendor/spinel/LICENSE`. Bundled components retain their own notices in the pinned tree; the Spinel license does not replace those notices.
- Build dependencies fetched by upstream: Prism 1.9.0 and RBS 4.0.1, retaining their packaged notices. Their source directories are local build dependencies, not additional tracked imports.
- Reproduction: [Building and testing](building.md).
- Patches: each commit of the vendored Spinel fork (yuskesh/spinel) above upstream `e1d92f1e1` is described in [Spinel patches](spinel-patches.md).

This repository is distinct from spinel-fork, which is used by predecessor projects. Their pins and branches were not changed by this adoption.

### Patch 1: SPINEL_EXTERN_METHODS, 2026-09-23

Approved by the owner on 2026-09-23, as the vendor patch spinel-ebpf's port
needs.

- **What it is.** The fork gains `src/codegen.c` support for external method
  definitions. A top-level method named in the comma-separated environment
  variable `SPINEL_EXTERN_METHODS` is emitted as an `extern` declaration with a
  fixed prototype (`sp_int` parameters named `lv_<param>`; `sp_int` return for
  a concrete Integer result, else `void`). Its body is skipped, and another
  translation unit linked into the program defines it.
- **Off unless the variable is set.** Both hooks call `extern_method_p`,
  which returns 0 when `SPINEL_EXTERN_METHODS` is unset or empty, and each
  returns only when it answers 1. With the variable unset, codegen takes the
  path it took before the patch. That is all of the patch: two helper
  functions, an early return in `emit_method_signature`, and one in
  `emit_method`; 48 lines, one file.
- **Source.** spinel-ebpf's Patch 1, fork spinel-fork, branch
  `c-emit-ir`, commit `8f65a5b5` (over upstream `83d1315d`), kept on
  `yuskesh/spinel` as the tag `spinel-fork/patch1-8f65a5b5`. It is
  replanted at the same three anchors of our `6d69d010`, as commit
  `573aa44c689830b60dc6f928282d08c9bfc9044d` on the new fork branch
  `extended/patch1-extern-methods-6d69d010`. No existing branch was moved.
- **The one local change.** The source spells the type `mrb_int`. At
  `8f65a5b5` that is `typedef intptr_t mrb_int;` (`lib/sp_types.h:90`); at
  `6d69d010` the same line is `typedef intptr_t sp_int;`, and `mrb_int` is no
  longer declared for generated C. The source, applied verbatim, made every
  program built with the variable set fail with `unknown type name 'mrb_int'`.
  The six occurrences (four in comments, two in code) are spelled `sp_int`. The
  other added lines are the source's.
- **Evidence, Debian 13 x86_64, at the new pin.** With
  `SPINEL_EXTERN_METHODS=add`, a program calling `add(2, 3)` linked against a
  C definition returning `a*100+b` printed 203; without the variable, the same
  source printed 5. Then, with REQUIRE_ALL=1: `tests/core/run.sh` 33 passed;
  `tests/native-core/run.sh` 18 passed; `driver.sh` 44 passed; `ledger.sh`
  23 passed; `tests/app/contract.sh` 66 of 66. None failed or skipped.
- **Reproduction.** `git -C vendor/spinel show 573aa44c`.

### Upstream synchronisation, 2026-09-21

- Fetch source: https://github.com/yuskesh/spinel.git; upstream
  https://github.com/matz/spinel.
- Upstream revision taken: `8279058d0deb5b7642d4152e3d2d8634b5f5972b`,
  authored 2026-09-21, tree `ee9bd528df2bbe2f606afa6551d97af95d6a4ba7`.
- **485 commits** on from the previous sync point `d9eb8456` (2026-09-09).
  The fork's `master` was fast-forwarded to it — `d9eb8456` is an ancestor,
  485 gained and none lost — and is the identical commit to upstream master,
  not merely the same tree. No branch was force-pushed and no ref deleted.

**Why it was taken.** The pinned compiler's type inference was exponential in
the depth of a nested expression: `infer_type` wrote its cache and never read
it, while each arm of `infer_call_inner` re-asked for the receiver. Measured
here on the same host and fixtures, compiling `a + a + …`: 0.077 s at 12
terms, 0.234 at 14, 0.914 at 16, 3.611 at 18 — about four times longer for
every two terms. A twelve-link method chain `a.succ.succ…` took 49 s. Upstream
fixed it with a generation-stamped per-tree memo in `infer_type`, present at
the revision above. On the same fixtures the synchronised compiler is flat:
0.006 / 0.005 / 0.009 / 0.016 s for the same four term counts, and 0.004 s for
the twelve-link chain. Answers were compiled, run and compared with `ruby`.

**The patch stack.** The fourteen local commits were rebased onto the new
master as three new branches, one commit per original, subjects unchanged and
in the same order. The three pre-existing branches were left untouched, so the
previous pin `cad0ad14` remains reachable.

| branch | tip | commits |
|---|---|---|
| `rebase/arena-process-lifetime-8279058d` | `4c2b3e098138786479c011bde65a77b286d0f141` | 7 |
| `rebase/core-selected-root-seam-8279058d` | `c77a2035b06425ffcbbf49bed65a7389397a7216` | 11 |
| `rebase/core-input-ledger-8279058d` | `6d69d010e283ee69118dd47e072a0ecbfbdc87ae` | 15 (the stack's 14, at `cb02f809`, plus the arena re-record below) |

**What conflicted, and how it was resolved.** Six of the fourteen; the other
eight applied unchanged. Each rebased commit's own message records its
resolution; in summary:

- *The arena's object allocator.* Upstream moved `sp_gc_alloc` out of
  `lib/sp_alloc.c` into `lib/sp_slab.c` — a file that did not exist when the
  patch was written — and split it into a lean front and a static
  `sp_gc_alloc_full`. The arena branch is re-applied at the top of the new
  `sp_gc_alloc`; one branch still covers the whole path, because
  `sp_gc_alloc_full` is static and its only callers are the three tail-calls
  inside `sp_gc_alloc`. The later commit that adds an overflow guard to that
  branch moves with it.
- *`lib/sp_gc.h`.* Upstream added declarations at three anchors the patch
  opens a conditional at. They are placed outside the conditional, which both
  configurations need, and the `#if`/`#else` still brackets what it bracketed.
- *`sp_gc_collect`.* Upstream added a preamble (a concurrent-sweep wait and
  `sp_slab_runs_release`). The arena's early `return` is placed **before** it:
  the patch's contract is that the function returns at its first statement,
  since every other collector entry funnels through it.
- *`src/codegen_fold.c`.* Upstream added `nd_callee` immediately before the
  `buf_printf` the patch replaces; upstream's line is kept and the patch's
  conditional follows it, with the `buf_printf` surviving as the else arm.
- *`Makefile` and `.gitignore`.* Additive collisions. The local side of every
  `.PHONY` conflict carries a stale copy of upstream's target list, so
  upstream's list is kept each time and only the patch's own `.PHONY` line
  taken; keeping the local copy would have deleted four targets upstream had
  added.

**One stub the original did not have.** Upstream grew a second rbval mark
entry, `sp_mark_rbval_scratch`, which handles the scratch slot and then calls
`sp_mark_rbval`. Every mark is a no-op under `SP_PROCESS_ARENA`, so the new
entry is stubbed like the one it wraps. Without it an `--arena` build fails on
an implicit declaration from `lib/spinel_rt.h`. This was found by running
`make test-arena-guards` on the rebased tree, not by reading the diff.

**The default build is unchanged.** The arena commit claimed that with
`SP_PROCESS_ARENA` undefined the build is byte-for-byte a pristine build of
the same revision. That claim was re-measured rather than inherited, because
the branch now sits in the slab's allocation hot path: building that commit
alone against a pristine build of upstream master compares 124 artifacts, of
which 122 are byte-identical — including `build/sp_slab.o` itself. The two
that differ are `build/csrc/main.o` and `bin/spinel`, and the difference is
the build stamp: `src/main.c` is identical between the trees, both objects are
52,712 bytes, and the entire `strings` difference is the embedded commit count
and short sha, which any commit changes.

**The contract reader.** `tools/contract/spinel_typedump.c` links the vendor's
objects through one narrow header so that an upstream rename is a compile
error. Across the 485 commits the four headers it reads changed by +181 lines
and −10; it compiles and links against the synchronised tree unchanged, and
its output is byte-identical to the previous pin's on the fixture sources
under `tests/core-report/` and `tests/core-stack/`, on all four faces.

**Where the two pins do differ.** On the packed DOOM CORE source
(21,560 lines) the reader's `ast` and `locals` faces are byte-identical, and
its `nodes` and `methods` faces are not: twenty-five methods' inferred return
type is reported as `poly` where the previous pin reported `int`, and the call
sites of those methods follow. No change is in the other direction and no
other column moves. Two of the twenty-five are entry methods, `dc_sp_lindex`
and `dc_sp_fplane`. **The objects are unaffected, measured on all forty-two
entries:** each was built twice with the same kernel, compiler driver and
stage, once with a reader built against each pin, and all forty-two objects
are byte-identical (5,851 s; per-build mean 46.2 s under the new pin against
93.1 s under the old). The kernel derives its own types on a contract path and
does not read the producer's method return types, which is why the change in
the reader's report does not reach the object. The freestanding emitter does
read them (`tools/mlir/native/lib/Freestanding/Emit.cpp`, the
`AbiWidthMismatch` check), so a freestanding entry whose inferred return
widened would be refused there; the six fixtures `tests/core/run.sh` uses are
identical on all four reader faces under both pins, and that lane passes.

**The arena suite's declared transitions were re-recorded.** The fork's
`scripts/arena-expected.tsv` was recorded against the previous pin; upstream's
485 commits added and fixed tests, so the declared set no longer matched. The
commit at the pinned revision is the file `scripts/arena-suite.sh --declare`
writes there, not a hand edit: 267 rows became 280, with 30 removed (28
because the test now passes in both legs, where no transition is recorded; one
test no longer exists upstream; one changed kind) and 43 added (25
`pass -> rejected`, 9 `error -> error`, 5 `fail -> fail`, 3
`pass -> capacity`, 1 `error -> rejected`). The invariant that makes
re-recording safe holds over all 280 rows and held over the previous 267: no
row takes a program that passes with the collector to anything other than
`rejected` or `capacity`. `make test-arena` at the pinned revision, from a
clean tree: exit 0 in 749 s, "the 280 declared transitions are exactly the
ones seen", tree clean afterwards. `make test-arena-declare` is a recorder and
not a check — it overwrites the declared file — and is not counted as one.

The gate's failure report understates a change: it prints
`diff -u want seen | tail -n +4 | head -60`, so the run that prompted this
showed 17 removals and 8 additions where the whole diff held 30 and 43. The
comparison itself is over the whole file; only the report is truncated.

**Known upstream state at `8279058d`, for which no patch is carried.**

- *Generated C that does not compile under `--int-overflow=promote`.* The nine
  `error -> error` additions above fail at C compile time in both the collector
  leg and the arena leg, and build and run without that flag. Two shapes:
  `assignment to 'sp_IntArray *' from incompatible pointer type
  'sp_PolyArray *'` (`poly_method_return_kinds`), and `incompatible type for
  argument 2 of 'sp_poly_bitop'` from `packages/set/set.rb`
  (`builtins_flat_map`, `builtins_filter_map`, `builtins_min_max_by`,
  `ivar_array_widens_on_read`). Seven of the nine are tests upstream added
  after the previous pin. A four-line reproducer of the related inference
  change — a local assigned from an untyped expression, used as one arm of a
  branch whose other arm is an integer literal, now reported `poly` where the
  previous pin reported `int` — builds identical C under both pins.
- *A literal shift count is compared with the host's word, not the target's.*
  Two sites write the width as a number. `emit_op_assign_lv` in
  `src/codegen_stmt.c` routes an op-assign shift through the checked helper only
  when the operator is `<<` and the literal count is negative or at least 63; an
  op-assign `>>` is never routed, so it is emitted as a bare C shift at every
  count. The literal-shift guard in `src/codegen_call.c` routes a binary `>>`
  only when `litc >= 64`. `sp_target_int_bits` exists and neither site reads it.
  The runtime is not at fault: `sp_int_shl` and `sp_int_shr` take the width from
  `sizeof(sp_int)`, and `sp_int_shr` returns CRuby's answer for a count past the
  word. Reproduced twice, independently, against pristine `8279058d` built with
  LLVM 23.1.1 — both times on macOS arm64, on one machine. It has not been
  examined on Debian x86_64, where the native symptom of the same undefined shift
  may differ: x86's shift instruction masks the count, so what the optimiser
  does with it, and whether anything traps, need not look like arm64's.
  **Natively the hole is exactly op-assign `>>` by a literal count of 64
  or more:** `x = -1; x >>= 64; puts x` is `-1` in CRuby; the default `-O2` build
  prints nothing and exits 133 (SIGTRAP), `-O 0` prints `-1`, and the emitted C
  is `lv_x = (lv_x >> (64LL));` — undefined behaviour the optimiser is entitled
  to use. `y = x >> 64` emits `sp_int_shr(...)`, a variable count is correct, and
  `x <<= 63` and `x <<= 64` raise `RangeError`. **On `wasm32-wasi`, where
  `sp_int` is 32 bits, the same two literals leave a window**, measured on macOS
  arm64 under node's WASI: the emitted C is a bare shift for `x <<= n` with `n`
  from 32 to 62, for `x >>= n` at every `n` tried from 32 to 64, and for
  `y = x >> 40`; run under `--int-overflow=raise`, `x = 1; x <<= 40; puts x`
  prints `0` at `-O0` and traps with `unreachable` at `-O1` and `-O2`, and the
  default build traps under `wrap` as well, where CRuby prints
  `1099511627776`; under `promote` it is correct. No patch is carried and
  Extended needs none: its hosted builds are for 64-bit hosts, where it takes an
  op-assign right shift by a literal of 64 or more and the largest literal
  op-assign count in `examples/` is 16; and a CORE object does not come from
  this code generator at all — the kernel lowers shifts itself
  (`lib/Frontend/Scalar/MlirGen.cpp`). Replacing both literals with
  `sp_target_int_bits` left the C emitted for all 3696 programs of upstream's
  suite byte-identical on the native target; that change is not applied here.
- *Upstream's own suite* gives `3758 pass, 1 fail` at both the pinned revision
  and pristine `8279058d` under `umask 002` — the same
  `implicit_conversion_protocol` mode-bits failure recorded at the 2026-09-09
  adoption — and `3759 pass, 0 fail` under `umask 022`.

### Upstream synchronisation, 2026-10-18

The arena commits this section describes were removed from the stack on
2026-11-01; see "The arena replaced by upstream --gc=none, 2026-11-01" below.

- Fetch source: https://github.com/yuskesh/spinel.git; upstream
  https://github.com/matz/spinel.
- Upstream revision taken: `e1d92f1e1923664db9deb5b9e1dc5e3b309d2cfb`,
  authored 2026-10-18, tree `1db847b1439ea33128a77743b6a33575dc10741e`.
- **10,280 commits** on from the previous sync point
  `8279058d0deb5b7642d4152e3d2d8634b5f5972b`. The old point is an ancestor:
  `git rev-list --left-right --count 8279058d...e1d92f1e1` reports
  `0 10280`. The pin is `ad4bb8c4238ddeaa801dc434b84f0b5cfd865af1`, nineteen
  commits above that revision; the stack branches below are published on the
  fork. Nothing was force-pushed and nothing was reported upstream.

**Why it was taken.** Revised decision 0015 admits signed integer arithmetic
in the native scalar slice. Upstream commit
`a07741ff1fad0304029eb8f515ba042f73f42f7b` moves Integer and Float nil out
of band, so `INT64_MIN` is an ordinary integer on both sides of the hosted
boundary. The earlier pin, `573aa44`, used that word as nil. The owner chose
the upstream update rather than keeping a pin-specific refusal of that
result. Arithmetic failures also need an external abort entry that bypasses
rescue frames while retaining the uncaught report and at_exit behavior; the
additional vendor patch is recorded below.

**The patch stack.** The existing sixteen local commits were replayed onto
the upstream revision, one commit per original, with subjects and order
preserved: arena, selected-root seam, input ledger, the historical arena
transition re-record, and Patch 1 (`SPINEL_EXTERN_METHODS`). Conflict
resolution follows the final `573aa44` contract rather than recreating an
intermediate root-disabling configuration that a later commit removed.

| local branch | tip | commits above upstream |
|---|---|---|
| `rebase/core-input-ledger-e1d92f1e` | `bc51716ea49e21519b5f66ca3f75c57885310100` | 16 |
| `rebase/core-abort-entry-e1d92f1e` | `3c498405714d84e86c3106581fa7b93cef55280f` | 17 |
| `rebase/core-no-sig-poll-e1d92f1e` | `6aa5f639508d615890f144e6b2c816f178cd2469` | 18 |
| `rebase/core-ffi-borrow-e1d92f1e` | `ad4bb8c4238ddeaa801dc434b84f0b5cfd865af1` | 19 |

The first integration candidate used the seventeen-commit tip; the
eighteenth and nineteenth commits are recorded below. The pre-existing fork
branches were not rewritten or deleted. The old pin
`573aa44c689830b60dc6f928282d08c9bfc9044d` remains reachable through the
retained `origin/extended/patch1-extern-methods-6d69d010` tracking ref; it is
not an ancestor of the rebased stack.

**What conflicted, and how it was resolved.** Twelve of the sixteen replayed
commits conflicted; the other four applied cleanly. Each conflicted commit's
message records its resolution in a 2026-10-18 synchronisation note.

- *Arena roots (`ee7479ff1`, `a7eabe762`).* Upstream added root frames and
  overflow segments for its root stack. Keep upstream's root macros, frame
  push/pop machinery and `SP_GC_STACK_MAX` in both configurations. Omit the
  first patch's intermediate root disabling; the later restoration is then
  already satisfied and retains its explanation and corpus change. Reading
  the final `upstream..tip` diff of `lib/sp_gc.h` confirmed that the root
  macros and stack limit are unchanged. Arena allocator, mark and barrier
  branches remain separate from that machinery.
- *Driver and build additions (`bec18c49f`, `1cb95e4c3`, `e0886c714`,
  `4c2b3e098`).* Retain upstream's full Makefile target list, help, options
  and timing probes alongside the fork additions. Preserve upstream's normal
  C-extension archive selection. The previously absent combinations of
  `--arena` with C extensions, `--target=wasm32-wasi` or
  `--exceptions=abort` are explicitly refused; no arena C-extension archive
  is introduced. The existing thread refusal remains.
- *Collector markers (`efe5be363`, `4c2b3e098`).* Upstream moved GC emission
  from `src/codegen_call.c` into `src/codegen_call_module.c`. Put marker
  writes at those actual emission sites while preserving upstream dispatch.
  The new keyword form of `GC.start`, `GC.stat(key)` and `GC.total_time`
  are also refused under arena. Keep every collector marker opt-in to the
  arena driver path, including the new total-time marker.
- *Selected-root seam (`2604505a6`, `2e8c153b0`, `cf219f968`).* Core symbol
  naming precedes upstream's explicit C-name branch; ordinary naming,
  debug linkage, nullable return emission and portability macros retain
  upstream behavior. The declaration-only early return restores the new
  proc-yield state and frees its temporary. Selection resolution stays
  immediately after analysis at the moved `codegen_program` entry, and
  mapping publication retains the new upstream helpers and required includes.
- *Input ledger (`300c19fcf`).* Combine the new timing probe and ledger write
  in `src/main.c`. Despite the parser rewrite, the successful `read_file`
  open site is still present and takes the recording hook unchanged. The
  two later ledger commits (`eddf2759e`, `cb02f809c`) applied cleanly.
- *External definitions (`573aa44c6`).* Keep upstream's backtrace and
  nullable-return helpers while inserting the existing opt-in canonical
  `sp_int`/`void` external declaration and body-exclusion branches.

The other clean applications were mapping destination preservation
(`c77a2035b`) and the historical arena transition record (`6d69d010e`).
The latter's expectations were not re-recorded against this upstream.

**Build compatibility corrections.** A fresh arena archive build exposed
`mruby.h` missing from the old regexp recipe. Fold the correction into the
archive-introduction commit: track `RE_HDRS`, add upstream's regexp shim
include directory, and pass the normal regexp build's `RE_CASE_FLAGS`.
The standalone allocator-guard harness then failed to link because upstream
now expects generated exception-subclass tables. Fold an empty `sp_int`
count/table, matching a program with no such subclasses, into the guard
commit. Allocator code and expected guard outcomes are unchanged by that
harness repair. Both corrections are recorded in their commits.

**The seventeenth commit: an abort entry.** Written for decision 0015 in this
repository, original fork commit `177782438477ae5ebdd76f38298a14cde1a351a7`, on
`e1d92f1e1`. It was cherry-picked without conflict as
`3c498405714d84e86c3106581fa7b93cef55280f`; stable patch IDs match, with no
local adaptation. Only `lib/spinel_rt.h` changes. The external, non-returning
`sp_abort_uncaught(cls, msg)` ignores armed rescue frames, runs at_exit,
prints the uncaught exception and exits with its status. It shares the
existing uncaught tail with `sp_raise_cls`; it does not enable exception
recovery from native core. Existing upstream and bundled notices remain in
place.

**Vendor validation, Debian x86_64, LLVM/Clang 23.1.1.** At the seventeen-commit
tip, with `umask 022`, direct compiler invocation (`NO_CCACHE=1`) and no
competing dependency build:

| command, from the vendor root | outcome | wall time |
|---|---|---|
| `make -j8 CC=/opt/llvm-23.1.1/bin/clang NO_CCACHE=1` | exit 0 | 26.712 s |
| `CC=/opt/llvm-23.1.1/bin/clang scripts/core-seam-check.sh` | 28 passed, 0 failed | 0.907 s |
| `make -j8 arena-archive CC=/opt/llvm-23.1.1/bin/clang NO_CCACHE=1` | exit 0 | 2.178 s |
| `CC=/opt/llvm-23.1.1/bin/clang scripts/arena-alloc-guards.sh` | 5 passed, 0 failed | 0.234 s |

A manual abort-entry probe also passed (0.507 s). A generated hosted program
armed RangeError rescue and ensure clauses and registered an at_exit hook;
`SPINEL_EXTERN_METHODS` supplied the selected method from a separate C
translation unit calling `sp_abort_uncaught`. Only the at_exit marker was
printed to stdout. Stderr was `integer overflow in + (RangeError)\n` and the
exit status was 1, with no rescue, ensure or post-call markers. A normal
hosted uncaught raise at the same tip produced the same outputs and status.
This checks consistency with that runtime, not an independent language oracle.

No CRuby oracle was run. `tests/gc-arena/run.sh` and
`tests/native-core/{run.sh,driver.sh,task2-probe.sh,macos-probe.py}` were excluded
because they contain reference-interpreter comparisons. The full upstream
suite and arena corpus were not run, the old arena transition declarations
were not adopted anew, and the earlier default-artifact byte-identity claim
was not re-measured. These vendor checks do not establish acceptance of all
Extended consumers or macOS compatibility.


#### Eighteenth local patch: builds whose loops do not poll for signals

Local commit `6aa5f639508d615890f144e6b2c816f178cd2469`, branch
`rebase/core-no-sig-poll-e1d92f1e`, directly above the abort entry
`3c4984057`. No earlier patch was rewritten; existing notices remain.

Upstream `afd8ef8a0` gives each loop's back-edge, or its proved condition, a
poll that calls `sp_sig_poll_raise` when a signal is pending. The gradient
generator (`tools/grad`) requires a differentiated method to reach no
allocation and no non-raise abort, and that poll reaches both, so every
declared gradient whose loop is not a pure region was refused. Upstream has
no way to leave the poll out; the owner chose an explicit opt-in.

`--no-loop-sig-poll` (exported to codegen as `SPINEL_NO_LOOP_SIG_POLL`) omits
the back-edge and condition polls. The method-entry poll on a call cycle is
kept. The generated C starts with `#define SP_NO_LOOP_SIG_POLL 1`, so a
consumer can check that a missing poll comes from this flag. With the flag, a
signal that arrives during such a loop waits until the program reaches
another safe point, and a loop that never ends is not interrupted. Without
the flag, the commit message records byte-identical C for 400 of 400 upstream
`test/*.rb` against `3c4984057`. Only `tools/grad/spinel-gradgen` passes the
flag (`084de8d`), and it checks that the C it compiles has no loop poll.

#### Nineteenth local patch: mutable String FFI borrowing

[Decision 0016](decisions/0016-ffi-mutable-string-borrow.md) was accepted on 2026-10-19.
The native implementation is local commit
`ad4bb8c4238ddeaa801dc434b84f0b5cfd865af1`, branch
`extended/ffi-mutable-string-borrow`, directly above the eighteen-commit parent
`6aa5f639508d615890f144e6b2c816f178cd2469`.
`git rev-list --count e1d92f1e1..ad4bb8c42` reports **19**. No earlier patch was
rewritten and nothing was pushed or reported upstream. Existing notices remain.

The explicit `:str_inout` argument spec lends an original mutable String's
owned bytes for a synchronous call; `:str` is unchanged. Changes are limited to
`src/ffi_spec.c`, declaration validation in `src/analyze_scope.c` and
`src/analyze_desugar.c`, handle demand/producer checks in `src/analyze.c`, the
ordered conversion in `src/codegen_call_class.c` and its internal declaration,
and inline prepare/publication helpers in `lib/sp_string.h`. Existing mutable
constructors already detach their owned `0xfd` payload from duplicates/read
faces; preparation verifies that ownership and rejects frozen data. Reusing an
owned buffer does not copy it. Publication invalidates the existing String
hash, ASCII and length-search caches after C returns.

A handle-shaped wrapper over a copied return is insufficient. The bounded
producer check requires original local/field/parameter routes or proven fresh
values; unknown identities refuse. The initial exclusions and their reasons
are enumerated in decision 0016, with explicit refusal fixtures. Callback
declarations and reflective-operation exclusions apply to the whole program;
argument demand follows emitted calls, preserving compilation of unused bodies.

The Extended raster declarations lend screen and zone with the new spec, while
WAD remains `:str`. The C seam declares those borrowed pointers as `char *`;
only screen is written. String cache publication replaces the old dummy
`setbyte`. Generated DOOM C passes the screen handle through `draw` to `frame`,
and takes both byte addresses after argument preparation, without
`sp_strbuf_read` / `sp_strbuf_read_pub` on either borrowed path.

Fresh Debian x86_64 checks used LLVM/Clang 23.1.1 and the candidate compiler:

| command/check | result |
|---|---|
| `make -j4 CC=/opt/llvm-23.1.1/bin/clang NO_CCACHE=1` in the vendor | exit 0 |
| `CC=/opt/llvm-23.1.1/bin/clang sh scripts/ffi-string-borrow-check.sh` in the vendor | 32 pass, 0 fail; 1.876 s |
| Native execution of existing `ffi_str_spec_aliases_arg`, `ffi_str_arg_boxed_strbuf`, `ffi_str_borrow_callback`, `ffi_io_buffer_arg` against their recorded expected output | 4 pass, 0 fail; 1.984 s |
| `CC=/opt/llvm-23.1.1/bin/clang sh scripts/core-seam-check.sh` in the vendor | 28 passed, 0 failed |
| `sh tests/raster/string-borrow.sh` with the candidate `SPINEL` | 4 passed, 0 failed |
| `RASTER_GPU=1 spinel examples/doom/bin/gpu_reject.rb -S` | exit 0; generation only |
| `ruby tests/raster/visibility-controls.rb` | 12 passed, 0 failed |

The new vendor runner checks six native programs and 26 refusal inputs. Native
cases cover aliases through fields/readers/parameters, independent duplicates,
repeated address reuse, empty and NUL-containing buffers, frozen rejection
before invoking C, hash/ASCII/length observations, and a side-effecting reader
whose later argument resizes then replaces its field and triggers GC. Expected
outputs are hand-written; no CRuby reference comparison ran. The full upstream
suite was not run.

On macOS arm64 with LLVM 23.1.1, at Extended `7c67e3f` and again at
`c5f3f66`, `tests/raster` passed 91 of 91 and `tests/raster/string-borrow.sh`
4 of 4. At `7c67e3f`, GPU and CPU `-shot` frames of DEMO3 at tics 100 and 400 passed
`tests/raster/visibility.rb` (97.5 to 99.7 % non-black). The tic-400 GPU and
CPU BMPs are byte-identical to the same program's frames at the old pin
`573aa44`, a change comparison with the same source, not an independent
oracle. At `c5f3f66` the DEMO1 frames passed the same visibility check at
99.36 % non-black or more. The owner accepted decision 0016 on 2026-10-19.

#### Observed upstream behaviour (not reported upstream)

The pin update exposed two String copying paths in the hosted DOOM source.
Upstream `adf9f0b9b` (merged as `9346225f4`, PR 5113) promotes ivars changed
by `setbyte` or `slice!` to shared handles so mutations through readers reach
the same object; its `string_ivar_reader_alias.rb` and
`string_ivar_reader_mutators.rb` tests express that correctness requirement.
`95996678d` centralises an existing handle read-face copy in
`sp_strbuf_read` / `sp_strbuf_read_pub` while preserving frozen state; it did
not introduce the copying policy. `5071a57ab` adds in-place handle `setbyte`
and tests aliases in `setbyte_handle_in_place.rb`, but direct ivar calls in
this program still reach the earlier `emit_array_call` copy shim rather than
that scalar fast path. A local handle alias reaches the in-place path.

In the unadapted program, `Renderer.clear_screen` copies a 64,000-byte buffer
for each of 64,000 pixels; the first status-bar refresh copies 10,240 bytes
for each of 10,240 pixels. Their payload copies total **4,200,857,600 bytes**.
On macOS, malloc-request bytes were **4,291,059,099** at both tic 500 and
5026, versus **169,899,415** at both points with `573aa44`. This is startup
work, separate from the continuing allocations below.

The masked-column fallback assigns `@dc_srcbuf = @zonewin`. At the new pin,
`@zonewin` is a mutable handle and that assignment emits
`sp_strbuf_read_pub`, copying its 128 bytes. At `573aa44` the program's
assignment is a direct pointer assignment. macOS self-measurement of DEMO1,
mode 1, gave these unadapted new-pin results:

| metric | tic 500 | tic 5026 | increase |
|---|---:|---:|---:|
| String allocations | 177,235 | 384,954 | 207,719 |
| String payload bytes | 4,213,903,514 | 4,240,491,547 | 26,588,033 |

Per-site allocation reports attribute all 207,719 additional Strings to
`Renderer.draw_masked_column`: 128 bytes each, plus the extra byte in the command-line
argument `5026` versus `500` (ARGV strings are copied by
`sp_str_dup_external`). The old pin reports 73,089 Strings at both points
and 9,013,831 / 9,013,832 payload bytes. The source's historical claim of
only twenty fallback columns does not describe this measurement. The new
pin and an upstream `e1d92f1e1` compiler with only the abort-entry header
patch generate identical DOOM C after normalising builtins paths. Thus this
codegen difference is upstream behaviour, not a conflict-resolution change
to collector markers or the external-method seam.

A snapshot is observable in general Ruby code: after assigning one String
to two names, changing a byte through either name must be visible through
both. The following diagnostic has the hand-written expectation
`88, 89, 88, 89`, one integer per line.
Both pins' default builds instead print `88, 89, 88, 66`; the new pin with
`--share-strings` prints the expected values. Each run exits 0 with empty
stderr. The fixture forces a handle on the old pin too: this demonstrates
an **existing default-mode sharing limitation**, not a newly introduced
semantic regression. Compile it with the selected Spinel and LLVM compiler,
then repeat with `--share-strings`; no reference interpreter is needed.
This is an observation of a known limitation, not a passing test that fixes the
incorrect final byte as an expectation. Save this diagnostic as
`/tmp/string-ivar-alias.rb`:

```ruby
class StringIvarAlias
  def initialize
    @scratch = +"ABCD"
    @source = ""
  end

  def run
    buf = @scratch
    buf.setbyte(0, 88)
    @source = @scratch
    buf.setbyte(1, 89)
    puts @scratch.getbyte(0), @scratch.getbyte(1)
    puts @source.getbyte(0), @source.getbyte(1)
  end
end
StringIvarAlias.new.run
```

```sh
vendor/spinel/bin/spinel /tmp/string-ivar-alias.rb \
  --cc="$LLVM_PREFIX/bin/clang" -o /tmp/string-ivar-alias
/tmp/string-ivar-alias
```

DOOM fills the window and consumes it synchronously before the next fill,
so that use does not observe the alias difference. The local adaptation
binds screen/backing handles once before clearing them and reads the scratch
window directly for that column, without publishing a snapshot through the
plain-String slot. Normal WAD/texture, job and fuzz paths retain their source
selection. The import manifest records the two changed source files.


**Adaptation validation, Debian x86_64, LLVM/Clang 23.1.1.** The same
`bench_tic.rb` mode-1 self-comparison, with `SPINEL_ALLOC_REPORT` and a
process-local glibc `LD_PRELOAD` malloc/calloc/realloc/free request counter,
produced the following. The request counter was checked with explicit
10-byte malloc, 20-byte calloc and 30-byte realloc calls: one of each,
two frees and 60 requested bytes. It counts cumulative requested bytes,
not peak live memory, and is a different instrument from the macOS DYLD
counter. There was no dependency rebuild or competing heavy build.

| build | Strings, tic 500 / 5026 | malloc-request bytes, tic 500 / 5026 |
|---|---:|---:|
| old pin, unadapted | 73,089 / 73,089 | 169,891,912 / 169,891,912 |
| new pin, unadapted | 177,235 / 384,954 | 4,291,052,636 / 4,291,052,636 |
| new pin, adapted | 74,650 / 74,650 | 88,261,692 / 88,261,692 |

The adapted String payload report is 9,417,757 / 9,417,758 bytes; the extra
ARGV digit accounts for the byte difference. All 23 reported GC allocation
categories total 80,931 allocations at both points. The libc counter reports
5,153 mallocs, 2 callocs, 1,504 reallocs and 4,659 frees at both points.
The three bench builds exited 0 (10.988 / 13.564 / 8.336 seconds); the
adapted 500 / 5026 runs exited 0 (0.763 / 7.585 seconds). These are execution
records, not a controlled performance comparison.

Generated C from `spinel examples/doom/bin/bench_tic.rb -S` has neither
`sp_strbuf_read_pub` nor `sp_str_concat` in `clear_screen`,
`refresh_background`, `draw_masked_column` or `draw_column`.
Two `sim_demo.rb` binaries, both compiled with the new pin, compared the
unadapted and adapted source over DEMO1 (5,026 tics), DEMO2 (3,836) and
DEMO3 (2,134). All 10,996 per-tic frame hashes and seven sampled raw frames
match. `tests/doom/compare-frame-streams.sh` checks each pair for the exact
requested tic count, contiguous keys and byte equality. This is a change
comparison with the same compiler, not an independent language oracle.

Other checks, with the prebuilt new-pin compiler, contract reader and native
tools selected explicitly (no in-tree dependency build):

| command | result | wall time |
|---|---|---:|
| `sh tools/doom/verify-sources.sh` | 55 files verified | 0.367 s |
| `sh tests/doom/ppm.sh` | 9 passed, 0 failed | 11.796 s |
| `sh tests/doom-core/entries.sh` | 31 passed, 0 failed | 1.598 s |
| `sh tests/doom-core/borrowed-calls.sh` | 49 passed, 0 failed, including ASan | 0.942 s |
| `sh tests/doom-core/object-relocs.sh` | 7 passed, 0 failed, 0 skipped | 0.381 s |

The first borrowed-calls run inside the sandbox reported 47/48: LeakSanitizer
could not inspect the process under the sandbox's ptrace restriction. The
same unchanged suite passed outside the sandbox. No failure was hidden by
disabling sanitizers. `tests/doom/run.sh` and the oracle-bearing doom-core
lanes (`control-flow.sh`, `source-pack.sh`, `state.sh`, `tick.sh`, `verify.sh`,
`screens.sh`, `native.sh`, `capacity.sh`, `native-scenario-diff.sh`) were not
run. No CRuby or other implementation was executed as an oracle, and this
record does not claim a full DOOM CORE gate or fresh macOS validation.

No issue or other report was sent upstream. The retained observation is:
handle-to-ivar reads can copy and lose observable identity in default mode,
and direct-ivar `setbyte` can miss the existing in-place optimisation.
Neither observation asks to revert upstream's reader-identity fixes or
establishes that switching the whole application to `--share-strings` is an
accepted replacement for this bounded source adaptation.

#### Extended adaptations to the new pin

Extended code that reads the compiler's output was adapted on
`integ/upstream-pin`. Each change is in its own commit; the main groups are:

- **Parser and node table** (upstream `c5964c6f4`). The contract reader and
  the eBPF in-process driver read the table that `sp_parse_file()` fills
  instead of loading `--dump-ast` text (`b4388e4`, `e23bc8d`). A second table
  with identical ids is an id-preserving copy, `tools/contract/spinel_nt_copy.h`;
  parsing twice in one process would see each `require_relative` as already
  included and build a different tree.
- **AST and analysis rewrites.** The core reader follows the new AST
  (`safe_nav` in place of `call_operator`, `depth`, `flags` and other new
  keys) without changing what it admits (`a16f21c`). The contract recognises
  three analysis rewrites instead of failing on them: the `Module.new`
  desugar, the dead-branch fold and the dynamic-send lowering (`d140c85`,
  `62318a7`, `ba20d92`). The DOOM reader maps the reader's class spellings
  back to Ruby names, so `Doom__Random` reads as `Doom::Random` now that
  `Random` is a builtin (`8bc5030`).
- **Integer domain** (upstream `a07741ff1`). `INT64_MIN` is an ordinary
  value: the scalar lane returns it and the core literal domain admits it
  (`d7364a9`, `ecbe5eb`). The arithmetic of decision 0015 is in `b170d4c`
  through `b19d35b`. Tests that expected the old sentinel or the old codegen
  were re-measured (`703bbd5`, `7a92c4c`, `ed58d8f`, `0ae1813`).
- **eBPF.** Upstream `FILE` records are parsed, both sides of `.ast`/`.ir`
  parse without the builtins splice, methods the analysis synthesises outside
  the pristine table are left out, and fixture regeneration finds the
  compiler as the driver does (`8c90a56`, `9e3b338`, `8885dac`, `4b35d76`,
  `cf3fb16`).
- **LLVM and grad.** The runtime bitcode follows the Makefile's member lists
  (`bccab64`); root frames, not only root pushes, are elided, including ones
  zeroed by `memset` (`1e27efb`, `fb70b6e`). Gradient kernels build with
  `--no-loop-sig-poll`, prove the elided IR allocation-free, and take C and
  extern names from the compiler's output with the target's symbol prefix
  (`084de8d`, `b4e20d4`, `581f11d`, `7392bf6`, `5554602`, `6a864a3`,
  `1c4287e`, `9a5af4e`).
- **WASM.** The reactor no longer resets `sp_Argf.idx` (`a28ffbe`). The WASI
  build defines `SP_NO_SIGNALS` and `SP_MAX_WORKERS=1`, the arena-only build
  sets `SP_STR_SHAPE_MAX=1`, and the four-page arena limit is kept
  (`8235e66`).
- **DOOM.** Hosted String snapshots are avoided at the source (`888a00f`,
  described above). The CPU jobs executor keeps its `Jobs` owner and reads the
  ring through `Jobs#zone_byte` (`0dfc2f7`). The GPU seam borrows the screen
  and zone with `:str_inout` (`d2f91c4`, `9fc265e`, `b5bb8c2`). Zone-window
  controls, state probes and the core packs follow those changes (`4b19ace`,
  `51c2a6b`, `bcac420`, `9e9ff29`). Doom-core B2, B10 and B14 no longer
  reproduce, fixed upstream by `a45a2d4e9`, `8596de678` and `55f849688`
  (`30389b7`). The audit's counts were re-measured after each source change
  (`ba66d35`, `a0af478`, `b093763`, `056b266`), and the import manifest and
  `examples/doom/NOTICE.md` record the changed files (`802c7f0`).

#### Validation of the pin move, 2026-10-19

LLVM/Clang 23.1.1 on both hosts; vendor `ad4bb8c42`. Suites ran as defined,
without modification or skips added. The CRuby comparisons run were
`tests/doom/run.sh` and doom-core `audit.sh`, `borrowed-calls.sh`,
`control-flow.sh` and `source-pack.sh`, on the owner's instruction of
2026-10-19. Results come from the last run of each suite. A suite whose
fix landed later was run again.

**Debian 13 x86_64.**

- *Repository suites at `7c67e3f`, 43 suites.* All exited 0 except the
  ones below: core, native-core, the scalar lanes, eBPF, the eleven
  applications, WASM `edge`/`arena`/`mvc-blog`, grad, freestanding, tensor and
  `raster/string-borrow.sh`. `shader` passed 28 with 2 skipped.
- *Doom-core at `c5f3f66`:* `abort-controls` 6/0, `fork-compat-controls`
  33/0, `loop-reports` 102/0, `screens` 19/0 (1 skipped), `state` 270/0,
  `tick` 118/0, `verify` 96/0 and `run-controls` 10/0.
- *CRuby comparisons at `831aa3a`:* `audit.sh` 265/265, `borrowed-calls.sh`
  49/49, `control-flow.sh` 59/59, `source-pack.sh` 81/81, and
  `tests/doom/run.sh` 5/5.
- *Failures that are not regressions.* Each failure below was run at main
  `96df4a7`, built from scratch with vendor `573aa44`, and at `831aa3a`.
  - `tests/gcmon`: 5 pass, 8 fail, 6 skipped on both, with identical FAIL
    lines.
  - `tests/raster`: `/usr/bin/ld: -f may not be used without -shared` on both.
  - `tests/spinel-vi`: `script: unexpected number of arguments` on both.
  - `tests/llvm`: 8 passed on both. Every ThinLTO case fails loading
    `LLVMgold.so`: 40 failures at main and 79 at the new pin. The counts
    differ because the cases are sampled from `vendor/spinel/test`.
  - `cb-schema` 72/73 and `cb-closure` 30/35 also fail at main.

  The causes are inferred, not verified: the gcmon and raster failures look
  like macOS assumptions, the llvm failures like GNU ld being selected without
  the gold plugin, and the spinel-vi failure like the difference between the
  BSD and util-linux `script` arguments.

**macOS arm64**, condition A.

- *At `7c67e3f`:* `tests/core` 21 pass, 12 fail and `schema` 72 pass, 1 fail.
  Both counts are unchanged from before the move.
  - Native-core: driver 45/0, arithmetic 171/171, `arith.sh` 50/0 with 1
    pending, ledger 23/0, and the macOS probe passes.
  - Grad: rules 8/0, hvp 6/0 and searchgate 5/0. `e076/twoexits` fails on
    the Mach-O `_` prefix, as it did before the move.
  - Other suites: buffers 115/115, adapter 64/64, shader 43/0, tensor 40/0.
- *At `c5f3f66`:* `raster` 91/0, `gcmon` 19/0, `verify` 96/96 (scenario
  diff 22/22), `tick` 118/118, `state` 270/270, `screens` 19/19 (1 skipped),
  `fork-compat-controls` 33/33 and `run-controls` 10/10. `abort-controls`
  passed 5 and failed 1, on bash 3.2's doubled TERM line, as it did before the
  move.
- *Segloop entry:* two kernel builds produced identical objects, with no
  undefined symbols and one export, `_spinel_core_dc_sp_segloop`.
- *String allocations:* DEMO1 mode 1 allocates 74,649 Strings at tics 500
  and 5026.
- *CRuby comparisons:* `audit.sh` 265/265, `borrowed-calls.sh` 49/49,
  `control-flow.sh` 59/59 and `source-pack.sh` 81/81 at `f3fcc80`, and
  `tests/doom/run.sh` 5/5 at `831aa3a`. The two commits differ only in
  `tests/doom/manifest.tsv` and `examples/doom/NOTICE.md`.

**Recorded but not resolved:**

- Nine freestanding scripts, `run_reject.sh` among them, take `W` from the
  environment (`W=${W:-...}`) and run `rm -rf "$W"` without checking it, so an
  exported `W` deletes that directory. One worktree was lost this way.
- The eBPF suite needs the in-process binary that `bin/spinel-ebpf compile`
  builds. Without it, seven cases are skipped. The Debian run built it first.
- The doom-core setup walk now reaches 347 definitions instead of 348. This
  is not asserted, and the cause is not verified.
- The disposition table in `docs/core/doom-stage2-scope.md` disagrees with
  the measured counts. This predates `0dfc2f7`, and no `docrow` checks it.
- `examples/doom/core` lies outside the directories `verify-sources.sh`
  checks.

### Patch 2: spinel-mlir M1–M3, the spinel_facts contract v2, 2026-10-25

Approved by the owner on 2026-10-24, including the vendor patch, and
confirmed on 2026-10-25 for the three steps that need it: the new fork
branch, the pin move and the flag-off comparison below.

- **What it is.** Three opt-in additions to the compiler. Without their flags
  Spinel does what it did before.
  - M1, `--emit-mlir=<path>`: write Spinel's facts about one run, the
    parsed and analyzed AST, the inferred types and the codegen evidence,
    as a generic-assembly MLIR module of the `spinel_facts` dialect. The flag
    is a mode of its own: it refuses `-S`, `-c`, `-o`, `-E` and the other
    emit modes, writes nothing to stdout and links no MLIR library.
  - M2, `--analysis-root=METHOD:TYPE[,TYPE...]` (with `--emit-mlir` only,
    repeatable up to 16 times): seed the analysis with a top-level method and
    its argument types, as contract version 2 records.
  - M3′: check the original-file positions the facts carry, and give a node
    that spans two files no position.
- **The contract.** `third_party/spinel-mlir/spinel_facts.md` and
  `third_party/spinel-mlir/SPINEL_MLIR_PATCHES.md` are verbatim copies, in
  Japanese as written. The facts carry only target-independent facts; what
  is missing is asked of spinel-mlir's reviewer as an additive revision, and
  the files are not edited here.
- **Source.** The spinel-mlir repository (the bpf-mlir project's; it has no
  public remote), main `3accdcd47f491df257d9a1ed6936d2ee8d2b1945`:
  `docs/spinel_facts.md`, `SPINEL_MLIR_PATCHES.md`,
  `patches/M1-emit-mlir.patch`, `patches/M2-analysis-root.patch`,
  `patches/M3-source-map.patch` and `patches/m{1,2,3}/*`. The patches were
  made against upstream `086d514d3e2f10f8349fdedbdc2dd01dbd6c0f9c`, an
  ancestor of our pin, 9,545 commits behind it; none applied to it as it is.
- **Fork commits.** One per patch, on the new fork branch
  `extended/spinel-mlir-m1-m3-ad4bb8c4` over the previous pin
  `ad4bb8c4238ddeaa801dc434b84f0b5cfd865af1`. No existing branch was moved.
  Each patch was first applied to `086d514d`, where all three applied
  cleanly (270, 310 and 206 added lines, the ledger's figures), and those
  commits were cherry-picked onto the pin. The new pin is
  `376a7727e93b10569df4db7f2bae34b30b655f97`:

  | commit | patch | added | deleted | on the pin since 2026-11-01 |
  |---|---|---|---|---|
  | `a64056e8f` | M1 | 343 | 0 | `70c9f6650` |
  | `9ac32c35f` | M2 | 310 | 0 | `4bcb6d6a2` |
  | `a319eaf0d` | M3′ | 135 | 0 | `9c20d87a0` |
  | `376a7727e` | M1, M2: their settings defined in the library | 13 | 0 | folded into `70c9f6650` and `4bcb6d6a2` |

  `git diff ad4bb8c42 376a7727e` adds 801 lines in 15 files and deletes
  none. The last commit changes five of M1's and M2's own lines in
  `main.c`; no line of `ad4bb8c42` is deleted.
- **Local changes.**
  - *The hooks.* Each hook line of M1 and M2 in `main.c`, `codegen.c`,
    `codegen_util.c`, `spinel_parse.c` and `analyze.c` is the patch's line,
    placed where the code it hooks now is.
    `src/emit_mlir.inc`, `src/analysis_root.h`, `src/analysis_root.inc` and
    `src/analysis_root_emit.inc` are the patch's files, except for the
    revision below.
  - *The settings, in the library: a local change for tools that link
    Spinel's objects without `main.o`.* M1 and M2 defined their five settings
    (`sp_emit_mlir_enabled` and the others) in `main.c`. Tools here that link
    Spinel's objects without `main.o`, `tools/contract/build.sh` and the
    eBPF tools among them, then failed to link. The new
    `src/emit_mlir_globals.inc` defines them in `codegen_util.c` with their
    off values, and `main.c` declares them.
  - *`producer_revision`.* M1's `emit_mlir.inc` and M2's
    `analysis_root_emit.inc` wrote the fixed string `086d514d…+M1` and
    `086d514d…+M1+M2`. The contract asks for the real Spinel pin, so both
    name `ad4bb8c4238ddeaa801dc434b84f0b5cfd865af1` with the same suffix.
    spinel-mlir's consumer checks only that the attribute is present
    (spinel-mlir's reviewer, 2026-10-25).
  - *The pristine snapshot.* M1 took the unanalyzed table by loading the
    parser's text a second time. At our pin the parser returns a NodeTable
    directly, with no text form, so the new `src/emit_mlir_snapshot.inc`
    deep-copies the table right after parsing and before analysis, only
    under `--emit-mlir`. The copy owns what `nt_free` frees. Fields that
    the old text round trip dropped may appear in the pristine table; they
    are this pin's facts.
  - *M3′ instead of M3.* M3 kept a second line map, because Spinel let every
    PUSH marker, its own inserted requires included, consume one line of the
    parent file, so the entry file's nodes after an inserted `require` were
    off by the number of insertions. At our pin upstream marks an inserted
    require with `#<SPINEL_INSERT>`, which consumes no line, and
    `sp_build_line_map` already gives each line its original file and line.
    M3′ (`src/source_map_pin*.{h,inc}`, new files) therefore corrects no
    position. It keeps the contract's other two rules: every buffer line a
    node starts or ends on is compared byte for byte with the file and line
    the facts name, refused as `MLIR M3 unrecoverable span … reason=content`
    with exit 1 when they differ; and a node whose end lies in another file
    than its start, the root ProgramNode and StatementsNode when a required
    file comes first, gets no position (M3's addendum B).
  - *No `spinel_facts.splice`.* The op is optional, and M3′ does not emit it.
    At our pin every inserted require goes through `sp_prepend_require`, from
    thirteen insertion sites; eight of them are builtins (`gem`, `rbconfig`,
    `thread_group`, `object_space` and others) whose origin is none of the
    contract's origin values. Emitting them would need new values, which are
    the contract's to add.
- **Evidence, Debian 13 x86_64, LLVM 23.1.1.**
  - *Opt-in.* Without the flags, `-S` printed C with empty stderr and wrote
    no `.mlir` file. `--emit-mlir` with no path, `--emit-mlir=… -S` and
    `--analysis-root` without `--emit-mlir` each exited 2 with their
    messages. A successful `--emit-mlir` left stdout empty.
  - *Additive.* No deleted line, by `git diff ad4bb8c42 376a7727e`.
  - *Flag-off C, old pin against new pin.* This is an oracle, run for this
    import only. Our 601 tracked `tests/**.rb` at main `67eb2e8` went
    through `spinel FILE -S` from one install directory, first with the
    previous pin's `bin/spinel`, then with the new one. `builtins`,
    `packages`, `lib` and `include` were identical between the arms.
    - Both arms exited 0 with non-empty C on 391 fixtures, and the C was
      byte-identical on all 391.
    - Both arms exited 1 on the other 210, with byte-identical stderr. They
      are files hosted Spinel does not compile alone, such as CORE and
      freestanding sources and Ruby test drivers.
    - No fixture succeeded on one arm only.
    - A second run of the old arm also matched on 391 of 391, and so did
      the new arm rebuilt at `376a7727e`, stderr included.
    - A test-only one-byte change in one arm's C
      (`tests/app/fixtures/contract/app.rb`) was refused by name: `C bytes
      differ at byte 11255`.
  - *The facts' shape.* spinel-mlir's `--verify-only`, built from its
    `b1135cc` (code identical to `3accdcd`), exited 0 on modules from a
    plain program, three programs that make Spinel insert requires (Set
    after a comment, IO::Buffer, an enumerable call), a v2 module with a
    resolved root (`add:int,int`) and a v2 rejection. Before M3′ it exited 1
    on the two insertion programs, with `span and FileLineColLoc disagree`
    on their root nodes. In the entry files, every local-variable write
    sits on its original line (6 of 6).
  - *M3′'s refusal.* A program whose `#<SPINEL_SOURCE>` comment pins its
    following lines to a line with other text exited 1 with
    `MLIR M3 unrecoverable span … reason=content` and wrote no module; the
    same comment pinned to the matching line exited 0.
  - *The snapshot.* A scratch harness linked against the build checked
    five programs, the largest of 3,425 nodes. Right after the copy, the
    copy's `nt_dump` equalled the original's byte for byte. After every
    string, integer, reference and array of the original was overwritten
    and the original freed, the copy's dump was unchanged. A shallow copy
    planted as a control failed that check.
  - *Not run: Spinel's own `make test`.* It compares against CRuby and
    against recorded `.expected` outputs, so it is an oracle, and the owner
    chose not to run it for this import (2026-10-25). The evidence that the
    flag-off compiler is unchanged is the flag-off C comparison above. One
    run had started before that decision. It stopped after 13 s at
    `cext-compiler-test` ("CRuby differs") and printed no count. It was not
    repeated and is not part of the evidence.
- **License.** spinel-mlir has not chosen a licence yet; the owner decides
  at publication. Until then the imported files are marked as such in
  `docs/imports.tsv`.
- **Reproduction.** `git -C vendor/spinel log --oneline ad4bb8c42..376a7727e`;
  the flags are described in [Building and testing](building.md#writing-spinels-facts-as-mlir).

### Patch 3: spinel-mlir M4′, the typing probe, 2026-10-27

Decided by the owner on 2026-10-27 (option a): M4′ on the pin, with the move
of the probe's settings below. The fork branch push and the pin move were
confirmed the same day.

- **What it is.** One opt-in addition to the compiler: `--emit-typing-probe`,
  with `--emit-mlir` and at least one `--analysis-root` only. Spinel forks
  before parsing; the child analyzes the program without the roots and
  sends its types back, the parent analyzes it with them, and the module
  gains the dictionary `spinel_facts.typing_probe` (version 1): both sets of
  types, the child's stderr, the roots and the source's sha256. spinel-mlir's
  consumer (E079, E080) needs it for a tool that embeds a kernel struct
  (`[:struct, S]`), such as tcpretrans. Without the flag, Spinel does what
  it did before.
- **The contract.** `third_party/spinel-mlir/spinel_facts.md` and
  `SPINEL_MLIR_PATCHES.md` are now verbatim from spinel-mlir main
  `f96ac6d`. That adds the typing probe's section (E078, E079) and M4's
  entry in the ledger, and changes nothing else.
- **Source.** spinel-mlir main `e53c504`, `patches/M4-typing-probe.patch`
  (sha256 `78024f65af707f1dd7e754c56313e3568284e2c6dea86ba9c0431797b72cc69a`)
  and `patches/m4/*`. They were made against upstream `086d514d` with
  M1–M3. Its `scripts/check-m4-prerequisites` does not pass here: 2 of the
  13 M3 source files it records match. `git apply --check` fails on
  `main.c` (4 of 4 hunks) and `emit_mlir.inc` (1 of 2).
- **Fork commit.** One commit, `eee3df25b3ca` (M4′), on the new fork branch
  `extended/spinel-mlir-m1-m4-ad4bb8c4` over the previous pin
  `376a7727e93b10569df4db7f2bae34b30b655f97`. No existing branch was moved.
  The new pin is `eee3df25b3ca`.
  - Since 2026-11-01 the pin's M4′ is `67fba6d34`, with the same tree; see
    "Patches 2 and 3 folded, 2026-11-01" below.
  - `git diff 376a7727e eee3df25b` changes 11 files, adding 147 lines and
    deleting 1 (that line is changed, below).
  - The diff is the patch made and checked beforehand, sha256
    `672832e68bd59a0257c89ac26bb47565e9be23bf0cd04d6a1a877bed631ab5c8`.
- **Local changes.**
  - *Kept as they are:* `typing_probe.h`, `typing_probe_emit.inc`,
    `typing_probe_sha.inc` and the `analysis_root_emit.inc` hunk.
  - *Hooks moved to this pin's code:*
    - `main.c`'s four: the header; `typing_probe_main.inc` before `main`; the flag after the `--analysis-root` error branch; the probe's start after the analysis-root check, before `sp_parse_file`, where upstream calls `sp_parse_file_to_text`;
    - `emit_mlir.inc` includes `typing_probe_emit.inc` after `source_map_pin_emit.inc`, M3′'s name for `source_map_emit.inc`.
  - *`sp_m3_top_file`, which M4 reads and M3′ did not have.* It is
    defined in `source_map_pin.inc` and declared in `source_map_pin.h`.
    It is set where `sp_build_line_map` interns the top-level file, as
    upstream M3 set it. That is the one changed line of `spinel_parse.c`:
    `stk_file[sp] = sp_m3_top_file = sp_intern_file(toplevel);`.
  - *The probe's seven settings, in the library.* They are defined in
    `emit_mlir_globals.inc`, not in `typing_probe_main.inc` (`main.c`), for
    the reason Patch 2 moved M1's and M2's: `codegen.c` refers to them
    through `emit_mlir.inc`, and tools that link Spinel's objects without
    `main.o` would otherwise fail to link.
- **Checks (2026-10-27, on a scratch build of the same diff, before the
  commit).** There were 637 inputs: P002's 609 (105 positive, 504
  negative) and the 28 bcc tools of spinel-bpf-mlir v0.7.0. They were
  compared with a clean build of `376a7727e`. The flag-off comparison is
  old against new, so it is an oracle; the owner approved it, once.
  - *Identity control:* `376a7727e` twice, flag off: 637 of 637 the same bytes.
  - *Flag off:* the facts are the same as `376a7727e`'s for 587 of 637 by raw bytes, and for 637 of 637 once the two builds' directory names are swapped.
    - The 50 that differ are exactly the inputs that splice Spinel's builtins. Their facts carry each builtin's path, under the build's directory.
    - rc and stderr are the same for 637 of 637.
  - *Flag on (the 133 with roots):*
    - rc 0, a non-empty module, and `typing_probe` version 1, `complete = true`: 133 of 133;
    - the module without that dictionary is the flag-off module: 133 of 133.
  - *Controls:* the flag without roots is refused (exit 2, by name), and a flipped byte is found.
  - *Spinel's own `make test`, once (owner, 2026-10-27).* It compares with CRuby and with recorded outputs, so it is an oracle.
    - It ran under `umask 022` with LLVM 23.1.1 clang at `-j4`. It exited 2 after 13 s, at `cext-compiler-test` ("CRuby differs"), the same place as the one earlier run at `376a7727e` (Patch 2), and printed no count.
    - The difference is only `Hash#inspect`'s form, on two lines: the host's CRuby 3.3.8 prints `{1=>2, "key"=>"value"}`, and Spinel prints Ruby 3.4's `{1 => 2, "key" => "value"}`.
    - It says nothing about M4′, and the targets after it did not run.
- **License.** As Patch 2: spinel-mlir has chosen no licence; `docs/imports.tsv` marks the copies.
- **The routine suites at this pin (2026-10-27, on `feat/bcc-wave3`, once).**
  The pin moves for every user of the compiler, so the suites that use it ran
  once, at `-j4`:
  - native-core (`driver.sh`, `ledger.sh`, `run.sh`, `arith.sh`): all exit 0; arith has 50 passed and 1 pending.
  - `tests/core/run.sh` (33 passed), `core-report` (639 passed, 1 skipped, 72 s), `core-stack` (31 of 31, 1 skipped), `core-boundary/intrinsics.sh` (50 of 50) and `core-eligibility` (51 passed): all exit 0.
  - `tests/core-boundary/run.sh`: 9 of 12 lanes pass. The 3 that fail are the three `tools/test/known.tsv` names: schema's bad-version, framebuffer's drifted `executor.rb`, and closure's census (6 checks).
  - `tests/app/host.sh` (58 of 58), `build.sh` (113 of 113, 612 s) and `cross.sh` (48 of 48): all exit 0.
  - `tests/freestanding/run.sh`: every lane passed (156 s), with its oracle directories not run. The board lanes did not run without `FRDM_HOST`.
  - `tests/gc-arena/run.sh`: exit 0.
  - `tests/edge/run.sh`: 21 passed, 2 failed. The gatekeeper and edge-twin builds stop at `spinel-fs-emit: int-width-boundary: tb_allow` (and `prng_next`) `has an i64 boundary, which a 32-bit Integer refuses; use i32`, decision 0019's refusal.
    - This is an existing failure: main `635cd38`, at the old pin `376a7727e`, fails the same two builds with the same text.
    - It has been reported to the owner, who decides how the examples change. It is not in `known.tsv` yet.
- **Reproduction.** `git -C vendor/spinel log --oneline 376a7727e..eee3df25b`;
  the flag is described in [Building and testing](building.md#writing-spinels-facts-as-mlir).

### Patches 2 and 3 folded, 2026-11-01

Decided by the owner on 2026-11-01. Patch 2's five commits and Patch 3's
one become four, and the pin moves to the new tip. The compiler's source does
not change.

- **Why.** `376a7727e` moved M1's and M2's settings out of `main.c`, so
  that a tool linking Spinel's objects without `main.o` links. At the old
  M1 such a tool does not link (checked below). Folded, the new M1 and M2
  link one.
- **The fork branch.** `rebase/spinel-mlir-m1-m4-folded-e1d92f1e`, from
  `ad4bb8c42`. It is a new ref; no existing branch was moved.

  | commit | tree | made from |
  |---|---|---|
  | `70c9f66508768d67cbf9390285bebd836dd153d6` | `18423af7cc21` | M1 `a64056e8f`, with `376a7727e`'s M1 part: `src/emit_mlir_globals.inc` with M1's four settings, its include in `codegen_util.c`, and `main.c`'s declarations |
  | `4bcb6d6a250e1df8cf211ebd5e39d4f2009c2805` | `cd61aecf1c77` | M2 `9ac32c35f`, with `376a7727e`'s M2 part: `sp_analysis_root_spec`, and the file's comment as `376a7727e` has it |
  | `9c20d87a02af9688415366e66cb8255a096b26bd` | `f5a29b917ee9` | M3′ `a319eaf0d`, cherry-picked |
  | `67fba6d346074ca7ab40f0a5a7475cfa8eb39e39` | `ad295981233f` | M4′ `eee3df25b`, cherry-picked |

  Each commit keeps the subject, author and date of the commit it was made
  from. M1's and M2's messages end with a note, "folded 376a7727e's M1
  part, 2026-11-01" and the same for M2.
- **The same tree.** The new M3′'s tree is `376a7727e`'s, and the new tip's
  tree is `eee3df25b`'s (`ad295981233f60264cbb978dda63b3ca598a86bf`).
  `git diff 9ac32c35f 4bcb6d6a2` is `git diff a319eaf0d 376a7727e`.
- **The pin.** `vendor/spinel` moves from `eee3df25b` to `67fba6d34`.
  `git -C vendor/spinel rev-parse HEAD^{tree}` gives the same tree as before,
  so the tip's tests were not rerun.
- **Checked.** The compiler built (`make -j4`, rc 0) and the contract reader
  linked without `main.o` (`tools/contract/build.sh`, rc 0) at the new M1
  and at the new M2. At the old M1 `a64056e8f`, the same reader link fails
  with undefined references to `sp_emit_mlir_enabled`,
  `sp_emit_mlir_overflow`, `sp_emit_mlir_path` and `sp_emit_mlir_pristine`.
- **The old commits.** `extended/spinel-mlir-m1-m3-ad4bb8c4` (at
  `376a7727e`) and `extended/spinel-mlir-m1-m4-ad4bb8c4` (at `eee3df25b`)
  remain on the fork, so Patch 2's and Patch 3's commits and reproduction
  commands still resolve.
- **Reproduction.** `git -C vendor/spinel log --oneline ad4bb8c42..67fba6d34`.

### spinel-fork mirrored on yuskesh/spinel, 2026-11-01

Decided by the owner on 2026-11-01, so that the sources this repository cites
from the predecessor's fork can be read without making that fork public.
spinel-fork's branches are mirrored on yuskesh/spinel under spinel-fork/*.
Each ref is new, at the same commit; no existing ref of yuskesh/spinel was
moved, and its own `c-emit-ir` is a different branch.

| ref on `yuskesh/spinel` | commit |
|---|---|
| `spinel-fork/c-emit-ir` | `ecbd0f2a7cd134d5affc2bd705f0f0e83aa82101` |
| `spinel-fork/e189/debian-cp1-alt` | `164ef4c709357c74d4d37632385d0d7598445064` |
| `spinel-fork/e189/wasm-seams` | `e43b6589f38ad023a06469faf2074842af302de7` |
| `spinel-fork/sync/upstream-20260909` | `3f1430e03bad0efc66ef079a811914da324784c3` |
| `spinel-fork/sync/upstream-20260909-debian` | `164ef4c709357c74d4d37632385d0d7598445064` |
| tag `spinel-fork/patch1-8f65a5b5` | `8f65a5b5871d1b6e24c11ce8ac1aac002d1a72e3` |

- **The tag.** `8f65a5b5`, the source of Patch 1 above, is on no branch of
  spinel-fork any more; it was fetched from spinel-fork by its id. A tag
  holds it because it is one fixed past commit.
- **Unchanged:** spinel-fork itself, and the pins of the predecessor
  projects.
- **Where it is cited:** Patch 1's source, the imported reproducers below,
  [`tests/doom-core/fork/fixtures/NOTICE.md`](../tests/doom-core/fork/fixtures/NOTICE.md)
  and the stage-2 fork review.

### The arena replaced by upstream --gc=none, 2026-11-01

Decided by the owner on 2026-11-01. The fork's process-lifetime arena is
removed, and upstream's `--gc=none` takes its place. Its build limit
(`SP_ARENA_MAX_MB` and `SPINEL_ARENA_MAX_MB`) goes with it, and so does the
driver's refusal of GC operations: under `--gc=none`, `GC.start` is a no-op.
No upstream synchronisation is part of this: the base stays `e1d92f1e1`.

- **Upstream's commit.** `ba5891e0a9d711dd7d1df2bd64d5287aabc0157a`,
  "--gc=none builds a program with no garbage collector", by Yukihiro "Matz"
  Matsumoto, 2026-10-26. It is cherry-picked with its author and its message,
  including the `Co-Authored-By` trailer that upstream's message itself
  carries. Licence: MIT, as the rest of Spinel; the notice is
  `vendor/spinel/LICENSE`.
- **Two fork branches, both new refs.** The fork's ref listing went from 37
  lines to 39, and no existing ref moved.

  | branch | tip | made as |
  |---|---|---|
  | `extended/gc-none-67fba6d3` (A1) | `ae3a9fec787ad0a26ae8bd248b0c6e04adf487ba` | two commits on the previous pin `67fba6d34`: the backport (`ebca1f979`), then "Remove the process-lifetime arena; --gc=none replaces it" |
  | `rebase/gc-none-e1d92f1e` (A2, the pin) | `ed8c753a4ca0b82774d7a10ce062c00bbf5f579d` | 16 commits on `e1d92f1e1`: the backport, then the 15 non-arena patches replayed |

- **The same tree.** Both tips have the tree
  `602ebec941f2f59e9acc71be0b217b7de96e2db0`. A2 is accepted by that identity,
  and the fork checks below were run on A1.
- **Conflicts.**
  - A1: the backport had 1 region (`Makefile`'s `test-run` line). The removal,
    the reverse of `f85ddb444^..1d9dab3d9` and of `318e51753`, had 9 regions:
    `Makefile` 1, `src/codegen.c` 1, `src/codegen_internal.h` 1,
    `src/codegen_util.c` 1, `src/main.c` 5. Each kept the later patches' lines
    and dropped the arena's.
  - A2: the backport 1 (`Makefile`, resolved as in A1), `31ae75c6d` 7,
    `372f4be76` 1 and `468c48b0d` 1; the other twelve replays applied
    cleanly. Every region's replayed side held an arena block beside the
    commit's own lines, and only the arena lines were left out.
  - Each replay touches the same files as its original with the same counts,
    except `31ae75c6d`: its `src/codegen_util.c` adds 47 lines where
    `e97e56074` added 48, a blank line after an arena block.
- **Checked on A1**, built with the selected Clang 23.1.1:
  - `make deps` and `make -j4`: rc 0;
  - `make gc-none-test`: `gc-none-test: pass`;
  - `make test-core-seam`: `core seam: 28 passed, 0 failed`;
  - `sh scripts/ffi-string-borrow-check.sh`: `ffi-string-borrow: 32 pass, 0 fail`;
  - `bin/spinel --arena`: rc 1, unknown option; `--gc=bogus`: rc 1;
  - `make test-arena` and `make arena-archive`: rc 2, no rule.
  - Neither the corpus nor `make test` was run, and nothing was compared with
    the previous pin's output.
- **Checked on A2, at M1 (`468c48b0d`) and M2 (`7c4cfb9f4`).** Each was built
  in a fresh clone with no earlier build products: `make deps` and `make -j4`
  rc 0, and the contract reader linked without `main.o`
  (`tools/contract/build.sh`, rc 0).
- **The stale object.** The first M2 build was in the directory that had built
  M1, and its link failed (rc 2) on an undefined `sp_analysis_root_spec`.
  `src/emit_mlir_globals.inc` is not in the Makefile's `SPINEL_HDRS`, so
  `codegen_util.o` was not rebuilt. That is a defect of the published fork,
  recorded under commit 13 of [Spinel patches](spinel-patches.md); it is not
  fixed, so that the pinned tree stays the checked one.
- **The pin.** `vendor/spinel` moves from `67fba6d34` to `ed8c753a4`.
- **Unchanged on the fork:** `arena/process-lifetime`,
  `rebase/arena-process-lifetime-8279058d`,
  `rebase/spinel-mlir-m1-m4-folded-e1d92f1e` (the previous pin) and `master`.
  The arena's commits and the reproduction commands of the sections above
  still resolve.
- **Reproduction.** `git -C vendor/spinel log --reverse --oneline e1d92f1e1..ed8c753a4`;
  `git -C vendor/spinel rev-parse HEAD^{tree}`.

### The collector's event record, 2026-11-12

Decision [0036](decisions/0036-gc-event-record.md), patch 17 of
[Spinel patches](spinel-patches.md). Written here, not ported: no predecessor
had a per-slot record. (spinel-llvm's unapproved L8 used the name
`SPINEL_GC_TRACE`; nothing of it is taken, and the name is avoided.)

- **The fork branch.** `gc-events`, a new ref, at
  `c23d82a7c5d27a04de407a086fa8068b26f78aee`: three commits on `ed8c753a4`,
  `8e1ac9e2c` (the record), `edb7761b7` (the stack behind each allocation
  and collection) and `c23d82a7c` (the blocks malloc'd outside the slab). No
  existing ref moved.
- **Files.** `.gitignore`, `Makefile`, `lib/sp_alloc.c`, `lib/sp_alloc.h`,
  `lib/sp_gc.c`, `lib/sp_gc.h`, `lib/sp_slab.c`, `lib/spinel_rt.h`: 329
  lines added, 28 removed, the three commits taken together. Licence: MIT, as
  the rest of Spinel; the notice is `vendor/spinel/LICENSE`.
- **Built** with the selected Clang 23.1.1: `make deps`, `make -j4` and
  `make events-runtime`, rc 0.
- **Tested** by `tests/gcviz/run.sh`. Nothing was compared with the previous
  pin's build, and the full suite set was not run (the owner's instruction,
  2026-11-12).
- **The pin.** `vendor/spinel` moves from `ed8c753a4` to `c23d82a7c`.
- **Reproduction.** `git -C vendor/spinel log --stat ed8c753a4..c23d82a7c`.

### Upstream's Float-in-while fix backported, 2026-11-14

The owner's decision, 2026-11-14: move the pin by exactly one fork commit,
upstream `bd53f5938` ("A local a while multiplies keeps a kind that is no
Integer", alfonso, 2026-11-06) backported onto `c23d82a7c`. The rest of an
upstream synchronisation waits for one later sync.

**The defect it fixes.** At `c23d82a7c`, a local that a `while` loop
multiplies (`y = y * 0.5`, `y *= 0.5`) is seeded as a Bignum before the
round types its writes. The analysis takes `y = y * k` in a loop for
Integer growth. A Float write then meets that seed and the local becomes
untyped (`poly`). The freestanding route refuses it, either through
"returns `poly`" or by "assigns a Float to `x`, which whole-program
inference typed as an Integer".

#### Predictions (2026-11-14, before the pin moves)

These are written with the fork commit already made, but before the pin
moves in this repository or any suite runs on it.

1. **The fork commit.**
   - It is one commit on `c23d82a7c`: `cherry-pick -x` of `bd53f5938`, on a
     new fork branch.
   - It has one conflict region, in `src/analyze_pass.c` just before
     `bi_promote`. Upstream's context there declares `bi_memo`, which this
     base does not have and the fix does not use, so it is left out.
   - Files: `Makefile` (the fix's `infer-test` lines),
     `src/analyze_pass.c`, `test/while_mul_keeps_local_kind.rb` and its
     `.expected`. That is 243 lines added and 1 removed, the same as
     upstream's own commit.
2. **What changes here, beside the gitlink:**
   - the pin's text (this section, the Spinel baseline paragraph,
     `docs/spinel-patches.md` and `docs/roadmap.md`);
   - the gitlink's three copies under `tools/dist`
     (`manifest.json`, `p4-inputs.tsv`, `p4/phase-a.sh`);
   - E084's rejection row `n4_loop_mul`.
   No Extended source under `tools/` changes, and nothing else under
   `tests/`.
3. **What flips: one row.** E084's `n4_loop_mul`
   (`tests/freestanding/e084/reject/n4_loop_mul.rb`: `x = 1.0`, then
   `x = x * 0.5` in a `while`, stored into a `:f64_buf`).
   - Today `run_reject.sh` expects the refusal "assigns a Float to `x`,
     which whole-program inference typed as an Integer".
   - At the new pin, `spinel-fs-emit` accepts it.
   - With the runner unchanged, the row would read `REFUSE ACCEPT FAIL
     compiled`. So the row becomes an accepted row (`accept_emit`), as
     0041 stage 1 did for `n3_block`.
   - The predecessor's oracle table
     (`tests/freestanding/e084/oracle/tables/reject.tsv`) stays as it was
     recorded.
4. **Nothing else flips** in the suites run for this pin move.
   - A text search of the tracked `tests/` and `examples/` Ruby for a local
     multiplied into itself (`x = x * …`, `x *= …`) finds 20 lines.
   - **Selected suites.** Inside them, the only Float one is `n4_loop_mul`.
   - **Integer locals.** The others in those suites are Integer locals:
     `s = s * 10 + j` in `core-blocks`, `i = i * 2` in `core-report`'s
     `loops.rb`, and `num`, `damage` and `thrust` in the DOOM sources that
     `doom-control-flow` and `doom-borrowed-calls` read.

     The fix keeps a local's Bignum seed unless one of its writes gives a
     kind that is not Integer. So these keep their type, and every report,
     digest and refusal text in those suites stays as it is.
5. **The suites run** are those that read inference and codegen, as the owner
   set them for a one-commit pin move (2026-11-14):
   - `freestanding`, `core-run`, `core-report`, `core-blocks`, `core-stack`,
     `core-boundary`, `core-intrinsics`;
   - `native-core-driver`, `native-core-ledger`, `native-core-run`,
     `native-core-arith`;
   - `fiber-core`, `subset-reasons`, `subset-tables`;
   - `lowering-locations`, `lowering-reopened`, `lowering-split`,
     `lowering-duplicate`;
   - `doom-control-flow`, `doom-borrowed-calls`, `app-cross`;
   - `source-stamp`, `affected-controls`, `imports`, `dist-controls` and
     `oracle-check`.

   That is 26. Each passes, apart from the skips each suite already names
   when a board or tool is absent.

   The full suite set runs once at the end of the upstream synchronisation,
   not here. `freestanding/libm` is not on main yet (it is part of
   `feat/mpc-plugin-sdk`), so it is not run.
6. **Outside the run, and expected to move.** These read the same
   inference, but are not in the 26 and are not run here:
   - `tests/grad` (`tests/grad/run.sh`, not a row of `tools/test/tests.tsv`):
     E076's obstacle corpus expects `odecay` (`v = v * 0.9` in a `while`,
     obstacle O6, "the bigint promotion") to be refused. With the fix, `v`
     is expected to type Float, so that row is expected to stop holding.
   - E082's `newton_demo.rb` (`t *= 0.5`) and E076's demos (`t = t * 0.5`)
     may also infer differently.
   - `tests/compute`'s `poly.rb` multiplies a Float in a `times` block,
     not a `while`, and is not expected to move.

#### The move

- **The fork branch.** `pin/while-float-bd53f593`, a new ref, at
  `baddd25a966d9cd5c2f62a3e42a717285cb3d9fe`: one commit on `c23d82a7c`, `cherry-pick -x` of upstream
  `bd53f593856ab739ceb82795f0fdf25d9f850cf8`. Its author is upstream's; its
  message is upstream's, with the conflict's resolution and the
  cherry-pick line added. No existing ref moved.
- **The conflict.** One region, in `src/analyze_pass.c` before
  `bi_promote`, resolved as prediction 1 says. The added and removed lines
  are upstream's.
- **Files.** `Makefile`, `src/analyze_pass.c`,
  `test/while_mul_keeps_local_kind.rb` and its `.expected`: 243 lines added,
  1 removed. Licence: MIT, as the rest of Spinel; the notice is
  `vendor/spinel/LICENSE`.
- **Built** with the selected Clang 23.1.1: `make deps` and `make -j4`, rc 0.
- **The pin.** `vendor/spinel` moves from `c23d82a7c` to `baddd25a9`.
- **Reproduction.** `git -C vendor/spinel show --stat baddd25a9`;
  `git -C vendor/spinel diff bd53f5938~1 bd53f5938` for upstream's own change.

#### Results (2026-11-14)

The run was made at `ee1823d7`, from the branch's worktree, with this tree's
own builds (source-stamp clean):
- vendor `make deps` and `make -j4` (111 s);
- `tools/contract/build.sh`;
- `tools/mlir/native/build.sh` (41 s);
- `tools/llvm/build_rt_bc.sh`;
- the passes.

The 26 suites of prediction 5 ran once each, one at a time: 26 rc 0, wall
1,012 s.

- **Prediction 3 held.** E084's rejection table reads `n4_loop_mul fs-emit
  ACCEPT ACCEPT PASS`, and E084 reports `104 pass, 0 fail`. `freestanding`
  ends "every lane passed" in 353 s.
- **Prediction 4 held.** No other row or suite moved, as these counts show:
  - `core-report`: 741 passed, 0 failed, 1 skipped;
  - `core-blocks`: 44 passed, 0 failed;
  - `doom-control-flow` and `doom-borrowed-calls`: all checks pass;
  - `subset-tables`: 12 of 12.
- **The skips are the suites' own named ones:**
  - the FRDM board lanes (`FRDM_HOST` is not set);
  - the oracle sections (`NOT RUN (oracle)`);
  - `core-report`'s baseline kernel comparison (`BASELINE_KERNEL` is not set);
  - `core-stack`'s `REAL_IR` check (`REAL_IR` is not set).
- **Prediction 6, E076's rejects only (the coordinator's merge check):**
  `tests/grad/e076/rejects/run.sh` was run once, alone. It gave rc 1 in 6 s.
  - gradgen reported "1 target(s), 10 reject(s)": `odecay` was accepted,
    as a reverse target with `v0:float`.
  - Its gates were G3 `OK`, with gradient 4.304672100000002e-01 against a
    finite difference of 4.304672099997297e-01 (rel 2.705e-13), and G4 `OK`.
  - The check `none_accepted` failed ("1 accepted"), and `set -e` ended the
    script there.

  So `expect.tsv` now marks `odecay` `accepted`, and `run.sh` checks:
  - that exactly the rows marked `accepted` are accepted;
  - that each of them has G3 `OK`;
  - the refused rows, counted without them.

  Each check records its result rather than ending the script. The
  corpus's comments and `tests/grad/README.md` say so. The predecessor's
  oracle tables under `e076/oracle/` stay as recorded.

  Run once more after the change: rc 0 in 9 s, 16 checks, all `PASS`
  (`only_expected_accepted`: odecay; `accept_odecay`: G3 OK; `reject_rows`:
  10).

  Then `tests/grad/run.sh` was run once, whole, at `0fa5cd89`, in 37 s.
  It ended "every case passed":
  - E076: twoexits 3, rejects 16, demoB 4 and demoA 10 pass;
  - E082: rules 8, hvp 6 and searchgate 5 pass;
  - gates/g5: 15 pass;
  - 0 fail in each case.

  So E082's `newton_demo.rb` and E076's demos, which multiply a Float in
  a loop, still pass. Not run: `tests/compute`.

### Upstream synchronisation, 2026-11-14

The owner's decision, 2026-11-14 (relayed by the lead): synchronise
`vendor/spinel` to upstream Spinel's head in one step, not staged. The
upstream revision was fixed once at the start for both sides:
`f8ff019399539dfa41ad99d52fb9d11039905d73`. Nothing was reported upstream
and no CRuby oracle ran.

- **Predictions**: written before any code changed, in
  [docs/reports/2026-11-14-upstream-sync-predictions.md](reports/2026-11-14-upstream-sync-predictions.md)
  (the fork side, then this repository's side). The results are recorded
  there beside them.
- **The fork**: the stack replayed onto `f8ff01939` on the fork's
  `sync/upstream-f8ff0193`, tip `4e0a59bd9`, 23 commits. The two upstream
  backports (`--gc=none`, `bd53f5938`) left the stack, since `f8ff01939`
  contains them; the ARGV fill order (`3ac5c2853`, the unmerged
  `feat/argv-fill-order` here) joined it; four commits are new, two of them
  for String handles after the first full suite run. Each commit is
  described, with the old-to-new map, in
  [Spinel patches](spinel-patches.md#the-2026-11-14-synchronisation). The
  fork branch is on GitHub as `sync/upstream-f8ff0193` at
  `https://github.com/yuskesh/spinel.git`, pushed as a new branch with no
  force.
- **The upstream changes this repository had to read**:
  - `7bc3fe018`: the analysis blanks a top-level method no node names
    (`prune_unnamed_methods`). The contract reader recognises the blanked
    method as an analysis rewrite (`PrunedMethod`), and the CORE kernel
    names its roots to the reader (`spinel-typedump --keep-method`), which
    the fork's prune keeps (entry 22).
  - `f49a94feb`: the analysis puts the one expression a pair of parentheses
    holds in their place; the reader recognises it (`ParenPeel`).
  - `556c840b1` and `3fd464a5a`: options are globals rather than
    environment variables, and a node's position integers live in the node
    rather than its integer list; the reader turns positions on through the
    global and copies and prints the position slots.
  - New AST fields: `DefNode.locals` and `CallNode.ignore_visibility`. The
    CORE checker reads each only under an exact rule.
  - Block parameters live in slots named with a per-method tag
    (`i__bp4pick_9`) rather than the block's id; the checker and the
    lowering read the slot's name from the nodes face.
  - The entry is parsed on its own before a required file is spliced in,
    and a top-level `X.prepend(M)` is written out as nodes the parse does
    not have. `spinel-fs-emit` still names the file a split construct
    crosses into and `Integer.prepend`. On the CORE route the reader now
    refuses the top-level prepend before the checker's verdict.
- **This repository's commits** (branch `sync/upstream-spinel`):
  - `21d69d56`: `tools/test/source-stamp.rb` reads a worktree's own vendor
    store first.
  - `3e593f56`: the contract reader (rewrites and positions), with the
    suite `contract-rewrites`.
  - `079e7bfa`: `spinel-fs-emit`'s named refusals.
  - `efd4923d`: the CORE checker's fields and slot names and
    `--keep-method`, with the suite `core-upstream-fields`.
  - `5267c4eb`: `tests/source-stamp` reads the same stores as the tool.
  - `1d274b34`: `core-eligibility`'s two top-level prepend cases expect the
    reader's refusal.
  - `57a817d2`: `tests/spinel-fork/argv-fill.sh` from
    `feat/argv-fill-order`, re-pinned to the new ARGV line. That branch
    (tip `776a8166`, above `6ee1d51d`, which pinned `3ac5c2853`) was never
    merged and was deleted after this synchronisation reached main
    (`38d9b98e`): its fix is in the pin as the fork's `b1b0702da`.
  - `edf00fab`, then `e4536cd0`: the gitlink (`b1b0702da`, then
    `4e0a59bd9`), the dist pin lines and these documents.
  - After the first full suite run, the paren peel in three more readers:
    the CORE checker (`9385cc61`), spinel-bpf-mlir's Go frontend
    (`0cd88175`) and the shader tools' cross-check (`06e383e1`).
  - The runtime's new calls on the hosts without a C library of their own:
    `getuid`, `getgid` and `isatty` on zephyr-full (`8490a34d`), `isatty`
    on bare-full (`8ae19c64`), `sock_recv` in the wasm shim (`3b9592ae`).
  - `29311d82`: edge-arena's catch_int is an ordinary check (the defect no
    longer reproduces); `506d28cb`: gcviz re-pinned to String handle
    objects; `f8687851`: raster-string-borrow is a known failure.
- **Open items** (not part of this synchronisation):
  - raster-string-borrow: `GpuRaster#frame` copies `@wad` on every GPU
    frame, since upstream holds a String variable as a mutable handle. A
    borrow route is a fork follow-up.
  - Storing `nil` into a StrArray that is also held elsewhere still widens
    it into a copy the other holder does not see. The same happens on the
    previous pin (`baddd25a9`), so it is not from this synchronisation.
  - The CORE checker does not check the fields of a block loop's
    `CallNode`; this predates the synchronisation.
  - doom-source-pack fails on `main` since 0042 stage 2 (`d890b574`): `>>`
    is now proved, so the packer test's undeclared `fixed_mul` is refused
    only for its top-level constants and no longer names
    `unproved-arithmetic`, which the test and `examples/doom/core/README.md`
    expect. Closed by `main`'s `2bf05f53`. After the rebase onto `88750448`
    it passes against this synchronisation's `vendor/spinel` and kernel
    (104 / 0).
- **Not predicted** (recorded as deviations beside the results): the
  CORE field rules, the block slot names, `--keep-method` in the kernel and
  its callers, the two named refusals in `spinel-fs-emit`, the reader's
  refusal of a top-level prepend on the CORE route (the program is still
  refused, one layer before the checker's verdict; teaching the reader the
  shape as a refused rewrite is a possible later step with its own review),
  and the source-stamp test's store.

## Zephyr v4.4.2 and SDK 1.0.1 (2026-09-22)

Pinned for decision [0014](decisions/0014-core-applications-on-zephyr.md),
Task 1 of [its plan](decisions/0014-core-applications-on-zephyr-plan.md). The
installation is outside the repository; the record is
[docs/toolchains/zephyr-v4.4.2/INSTALLATION-RECORD.md](toolchains/zephyr-v4.4.2/INSTALLATION-RECORD.md).

- Zephyr **v4.4.2**, commit `dccb09599635bdff17633fa7e9dab014b91dce90`
  (tag object `671f64aa79924606253238f801c494c84b02c2a0`), from
  https://github.com/zephyrproject-rtos/zephyr, with the modules `cmsis`
  `512cc7e8`, `cmsis_6` `30a859f4`, `hal_nxp` `7554bc0f` and `picolibc`
  `01254932` selected by a west project filter. Chosen as the newest tagged
  4.4.x whose `SDK_VERSION` is the SDK both hosts have.
- Zephyr SDK **1.0.1** (`arm-zephyr-eabi-gcc 14.3.0`), pre-existing at
  `~/zephyr-sdk-1.0.1` on both hosts; its host tools supply `dtc` and the
  `qemu-system-arm` (10.0.2) the `run` target uses.
- Python runs only inside the installation's venv (3.13.5 on Debian, 3.13.3 on
  the Mac), for `west` 1.5.0 and Zephyr's build; the `requirements-base.txt`
  and `pip freeze` digests are in the record and were byte-identical on both
  hosts. No `.py` file was added to the repository.
- Nothing was registered in `~/.cmake/packages`, and the record shows that
  `ZEPHYR_SDK_INSTALL_DIR` alone does not select the SDK: `tests/app/platform-facts.sh`
  confirms the tree and SDK used from the CMake log.
- Licences: Zephyr and its modules are Apache-2.0 (the SDK's toolchain is
  GPL with the runtime exception, picolibc BSD/MIT). No Zephyr source is
  copied into this repository; the probe under `tests/app/fixtures/platform`
  is original. Two build outputs derived from Zephyr's devicetree sources are
  tracked as fixtures (below).
- **Derived fixtures (Task 7, 2026-09-22; FRDM-IMXRT1186 added 2026-10-20 for
  decision 0021, its Cortex-M7 2026-10-21 for decision 0023).**
  `tests/app/fixtures/dts/mps2_an521/`, `tests/app/fixtures/dts/frdm_mcxn947/`,
  `tests/app/fixtures/dts/frdm_imxrt1186/` and
  `tests/app/fixtures/dts/frdm_imxrt1186_cm7/` hold the final `zephyr.dts` and the
  `CONFIG_` lines of `.config` that Zephyr v4.4.2 (`dccb0959`) wrote for
  `samples/hello_world` on `mps2/an521/cpu0`, `frdm_mcxn947/mcxn947/cpu0`,
  `frdm_imxrt1186/mimxrt1186/cm33` and `frdm_imxrt1186/mimxrt1186/cm7`.
  The DTS is the flattened output of Zephyr's `.dts`/`.dtsi` sources, which are
  Apache-2.0 (each node carries a comment naming the source file and line it
  came from); it is tracked so that `tests/app/board.sh` generates the board
  package from a recorded input. Origin, revision, board and digests are in
  `tests/app/fixtures/dts/README.md` and `digests.txt`; the licence notice is
  in that README.

## Imported component: the native core slice

- Source repository: spinel-llvm (a private predecessor repository).
- Source revision: `f8ad13c6d9dc990b116ba1c842c7881232f29585`.
- Adoption date: 2026-09-09.
- License: **the source repository states none.** It carries no `LICENSE` file
  and the imported sources carry no license headers. Both repositories have the
  same owner, so the import is the owner's own work moving between the owner's
  own projects, but the licence of these files is undetermined and must be
  settled before this repository is published. This is separate from, and does
  not resolve, the undecided project-wide licence noted below. Both were
  settled on 2026-11-20 (Project licence, at the top).
- Notices: `tools/contract/spinel_contract.h` reproduces two functions that are
  `static` in the pinned Spinel tree, `ty_tag_into` and `emit_file_path` from
  `src/codegen.c`, so that a dump can be compared byte for byte. Spinel's MIT
  licence and its copyright, Yukihiro Matsumoto, therefore apply to that part of
  the header. The reproduction is documented in the header itself.

### Original path to local path

| Original | Local | Contents |
|---|---|---|
| `tools/contract/` | `tools/contract/` | `spinel_contract.h`, `spinel_typedump.c`, `build.sh`, `README.md` |
| `tools/freestanding/spinel/` | `tools/freestanding/spinel/` | `freestanding.rb`, the declaration surface |
| `tools/freestanding/profiles/` | `tools/freestanding/profiles/` | `cortex-m33-zephyr.yaml` only |
| `tools/realtime/alloc_vocabulary.tsv` | `tools/realtime/alloc_vocabulary.tsv` | allocation vocabulary, read at configure time |
| `tools/mlir/native/` | `tools/mlir/native/` | the subset listed below |

Paths were kept identical so that a later import lands in place and so that a
diff against the source revision stays readable.

### What was taken from `tools/mlir/native`, and what was not

Taken: the root `CMakeLists.txt` and `cmake/`, the ODS directories for the
Spinel dialect and the SpinelToLLVM conversion, the headers under
`include/spinel-mlir/` except the SpBPF, Tensor and Target trees, the libraries
`Contract`, `Frontend/Scalar`, `Freestanding`, `Conversion/SpinelToLLVM` and
`Dialect/Spinel`, and the two drivers `spinel-fs-emit` and `spinel-fs-check`.

That set is what the two drivers link, determined from the build graph rather
than by inspection. Not taken: the SpBPF dialect, the Tensor and Target
libraries, the CAPI, `Support`, `Passes`, `Realtime`, the other thirteen
drivers, the unit tests, and the lit suite.

### Local changes

Five, all recorded here because none of them is a change to the contract:

1. `tools/mlir/native/CMakeLists.txt` adds `-fno-rtti` when the MLIR being
   linked was built without RTTI. The libraries here are declared with plain
   `add_library()`, so they do not inherit the flag that `AddLLVM` gives its own
   targets. Debian's LLVM packages are built with RTTI on and never showed this;
   the official LLVM release archive is built with RTTI off, and linking against
   it fails with `undefined reference to typeinfo for mlir::Dialect`. On an
   RTTI-enabled toolchain the block does nothing.
2. The same file no longer descends into the SpBPF ODS directories, the unit
   tests or the lit suite, which are not imported.
3. The same file no longer fails when no lit runner is found. The imported slice
   has no lit suite, and the official LLVM release ships neither `lit` nor the
   `FileCheck`, `count` and `not` utilities such a suite needs.
4. `lib/CMakeLists.txt`, `lib/Dialect/CMakeLists.txt` and `tools/CMakeLists.txt`
   list only the imported libraries and drivers.
5. `tools/mlir/native/build.sh` is rewritten for this repository: it defaults to
   `/opt/llvm-23.1.1`, builds the two drivers, and creates no virtual
   environment.

Added here rather than imported: `tools/freestanding/profiles/x86_64-linux-host.yaml`,
a host profile so the object can be linked into a C harness and executed. It
states the same three layers as the MCU profiles and changes no part of the
contract: `overflow: trap` with `spinel_trap` as the hook, `i64-internal`
bodies, and one platform extern. It is written in the pre-T5 form because the
native profile reader refuses the platform-first form outright, that form
needing the capability ledger this slice does not import.

No C, C++ or TableGen source file was modified. `diff -r` against the source
revision reports differences only in the CMake files listed above.

Later (2026-10-23, [decision 0026](decisions/0026-owning-the-core-lowering.md)
step 1): `lib/Frontend/Scalar/SubsetTables.cpp` is hand-maintained. At import
it said it was generated from `FS_ALLOC_NODES` and `FS_ALLOC_CALLS` in
spinel-llvm's frozen Python generator (`tools/mlir/spinel-mlirgen.py`) by
`docs/experiments/results/E175/mk_fs_tables.rb`; neither is imported. Its
keys (36 node kinds, 10 call names) and reasons are those of the import except
ConstantPathNode's reason, changed in `60a67f1`. `tests/subset-tables/check.rb`
pins them.

Later (2026-10-23, decision 0026 step 5): the 40 entries with a fixture moved
to `lib/Core/SubsetRefusals.cpp`, with a column marking the 7 node kinds the
CORE checker refuses as heap operations; the 6 unverified-inherited node kinds
stay in `SubsetTables.cpp`. Keys and reasons are unchanged, and the pin covers
both files.

### Imported component: the process-lifetime arena

**Removed on 2026-11-01.** The pin no longer carries the arena; upstream's
`--gc=none` replaces it. See
[The arena replaced by upstream --gc=none](#the-arena-replaced-by-upstream---gcnone-2026-11-01).
The record below is history.

- Source repository: spinel-llvm (a private predecessor repository), revision
  `f8ad13c6d9dc990b116ba1c842c7881232f29585`, where it is `SP_REQUEST_ARENA`.
- Carried into: `yuskesh/spinel`, branch `arena/process-lifetime`, at
  `5bc45ec19a372c6f4da29485a7ce35c81b9751cc`, which is what `vendor/spinel`
  pins on this branch. It fast-forwards the two earlier pins
  `cd5331fc28926d11bce2bbdadabea7696b4d4777` and
  `5f90226eb3d5293e43e2186840acbf6e5ab2e5a4`, and carries the review fixes:
  allocator overflow guards at all three arena entries and on the compile-time
  limit, strict environment parsing, GC detection by a marker the generator
  emits rather than a text search, and the corpus gate. The fork's `master` is
  unchanged at `d9eb845`, no branch was force-pushed, and no other project's pin
  was touched.
- Licence: the source repository states none, as recorded above for the core
  slice. Spinel's own MIT licence and its copyright continue to apply to the
  files the change edits, which are Spinel's.
- Original paths and local paths are the same: `lib/sp_gc.{h,c}`,
  `lib/sp_alloc.{h,c}`, `src/main.c`, `Makefile`.

What changed relative to the predecessor's version, and why:

- The unit is the process rather than the request, so there is no arena reset
  and no escape check. The names and the diagnostics say so.
- The root machinery is **not** disabled. The predecessor turned `SP_GC_ROOT`
  into a no-op for speed; that removed the `&local` those macros take, and a
  local that stays in a register instead is indeterminate after the `longjmp`
  that `catch`/`throw` and `raise`/`rescue` are built on. Five programs gave
  wrong answers because of it. Keeping the macros restores the default path's
  handling and its verified behaviour; it is not a claim that the underlying C
  rule is satisfied, which would need those locals declared `volatile` upstream.

  The smallest reproduction needs `--int-overflow=promote`, which is the
  suite-wide `SP_OV_FLAG`; the fork commit that carried the fix quoted the three
  lines without it, and without the flag the program prints 1 in every
  configuration and shows nothing:

  ```sh
  printf 'i = 0\ncatch(:done) { i += 1; throw :done }\np i\n' > /tmp/ct.rb
  spinel /tmp/ct.rb --int-overflow=promote -o /tmp/ct && /tmp/ct
  ```

  With the flag: CRuby 1, a pristine build of the base revision 1, this fork's
  default build 1, this fork under `--arena` 1; restoring the no-op macros makes
  the `--arena` build print 0.
- `sp_cell_scan_procint` was added to the gated branch. The predecessor's tree
  had three cell-scan helpers and this one has four, so the hand-written list
  was stale and 55 programs failed to compile.
- The arena's globals are named `sp_gc_arena_*` rather than `sp_arena_*`, so
  they fall under a prefix the generated reserved-name table already carries.
  Under the original name the default build changed: `def arena` would have
  started being mangled differently.
- Quoted speed figures were removed. They were measured on the predecessor's
  hardware, not here.

Evidence: with the define absent the build is byte-identical to a pristine build
of the base revision except for the embedded build revision. Under the arena an
artifact defines no collector symbol; the root bookkeeping remains, which is a
different thing from depending on the collector. `tests/gc-arena/` carries the
acceptance checks and `tests/core/` still passes on this pin.

### Predecessor validation assets not adopted

The predecessor's reject and gate runners were not run here, and the reason is
their dependencies rather than a missing test utility:

- Its `run_reject.sh` scripts drive `tools/mlir/spinel-mlirgen`, a shell wrapper
  that selects between implementations. That wrapper was not imported; this
  repository builds the two drivers directly.
- Its `run_gates.sh` scripts build and boot cross targets under a Zephyr SDK,
  `west` and QEMU, none of which is set up here, and some of them also use
  `python3` helpers.
- The predecessor's lit suite is a separate thing from those shell runners. It
  is what needs `lit` and the `FileCheck`, `count` and `not` utilities that the
  LLVM release archive does not ship.

Adopting any of them means re-checking it against its current runner first.

### Reproduction and evidence

Build and check commands are in [Building and testing](building.md). The
acceptance checks live in `tests/core/` and are run as a normal part of working
on this slice. Their scope, and what they deliberately do not cover, is stated
there and in that document.

## Baseline validation

This section records the starting baseline: the first end-to-end run of the pinned upstream compiler, with no Extended code in the picture. It describes the repository as it stood on 2026-09-09, before the core slice recorded above was imported, and it is kept in that state deliberately. Nothing in this section validates a tier boundary or an allocation policy.

What had not been started at that point was the migration, not the underlying work. The predecessor `spinel-llvm` already implemented a `core` / `arena` / `full` distinction and checked tier declarations against it, and none of it had been ported here. The first part of that migration has since landed; it is recorded above. Arena is still not imported.

Arbitrary coexistence of an arena with a long-lived GC heap is not finished work on either side. It remains a research question in the predecessor as well, and needs its own contract and validation before it is claimed; see [roadmap](roadmap.md).

The `gc-*` checks named below are upstream Spinel runtime checks. They are neither Extended work nor the predecessor's tier checking.

Validated tree: Extended `c8fb507e130db8b6d0625868a0ff42b6c3af8f5b` with `vendor/spinel` at the pinned revision above and no local patches to the submodule. Each run below used a separate clean checkout of that commit, not a developer working tree.

Debian 13 is the primary environment and the source of the full-suite result. This baseline records that host only, and claims no result for any other platform.

### Debian 13 with Clang 23.1.1 (primary)

Host: Debian GNU/Linux 13 (trixie), x86_64. GNU Make 4.4.1, ccache 4.11.2, `/usr/bin/ruby` 3.3.8 on PATH, `umask 022`.

Toolchain: `clang version 23.1.1`, built from llvm-project `6dfe1677ab8dffbc6ec13d53a1e0215d75147689`, installed at `/opt/llvm-23.1.1` from the upstream release archive `LLVM-23.1.1-Linux-X64.tar.xz` of tag `llvmorg-23.1.1`. Verified before use:

```sh
sha256sum LLVM-23.1.1-Linux-X64.tar.xz
# 832aeb58d105de1cabc7b982dd2c65de0610f7377df48ae8fc2dd8e97420a15c
gh attestation verify LLVM-23.1.1-Linux-X64.tar.xz \
  --bundle LLVM-23.1.1-Linux-X64.tar.xz.jsonl --repo llvm/llvm-project
# exit 0; SLSA provenance, built by release-binaries.yml at refs/tags/llvmorg-23.1.1
```

This toolchain is a host tool. It is not a tracked dependency of this repository and nothing here pins it.

All three compiler selectors described in [Building and testing](building.md) were pointed at that Clang: `CC=/opt/llvm-23.1.1/bin/clang` on each make command line, and a process-local shim directory first on `PATH` so that the `cc` the Spinel compiler executes for itself resolved to the same Clang. Nothing outside those processes was changed; the system `cc` remained GCC. `ccache` was on `PATH`, so the effective compiler was `/usr/bin/ccache /opt/llvm-23.1.1/bin/clang`; `CCACHE_DIR` pointed at an empty directory for this run, so no object was replayed from an earlier GCC run.

- `make -C vendor/spinel deps`: exit 0. Fetched Prism 1.9.0 and RBS 4.0.1.
- `make -C vendor/spinel -j8 CC=/opt/llvm-23.1.1/bin/clang`: exit 0. Every compile and link line in the build log went through the selected Clang: `grep -c '/usr/bin/ccache /opt/llvm-23.1.1/bin/clang'` reports 131, and a grep for `gcc` or `/usr/bin/cc` reports 0.
- Compiled and executed `puts 6 * 7`: output `42`; compilation and execution each exit 0.
- `make -C vendor/spinel -j8 test CC=/opt/llvm-23.1.1/bin/clang`: exit 0, summary `Tests: 3543 pass, 0 fail, 0 error`.
- Auxiliary checks in the same run all passed: RBS extractor tests (13 pass), `reject-test`, `backtrace-test`, `re-lit-test`, `byref-capture-test`, `ext-test`, `ext-cruby-test`, `rbs-seed-test`, `gc-minor-test`, `gc-phases-test`, `gc-threshold-test`, `gc-obj-budget-test`. No check reported a skip, and the log contained no warning about a missing `timeout` command.

The build log contained no `warning:` or `error:` line, but that is not evidence of a warning-free compile: `common.mk` sets `-Wno-all` in `CFLAGS`, and the per-test compiles discard stderr.

That the selected Clang, and not the system GCC, compiled the generated C was checked rather than assumed: `CC_KIND` resolved to `clang`; the Makefile wrote its precompiled headers under `vendor/spinel/build/pch/clangO2/`; `.comment` in `vendor/spinel/build/csrc/codegen.o` named only `clang version 23.1.1`; and one test was reproduced by hand through the same `CC` path, from within `vendor/spinel`:

```sh
./spinel test/alias_global.rb -c --no-line-map -o t.c
/usr/bin/ccache /opt/llvm-23.1.1/bin/clang -O2 -Wno-all -Wno-unknown-warning-option \
  -Wno-alloc-size-larger-than -Wno-format-truncation -Werror -Wno-unused-value \
  -Ilib t.c lib/libspinel_rt.a -lm -lcrypt -o t_bin
```

That produced a binary whose `.comment` named the same Clang, and whose output matched `test/alias_global.rb.expected` exactly.

### Debian 13 with GCC 14.2.0 (secondary, same host)

Same host and Ruby. `cc` was the distribution default, `gcc (Debian 14.2.0-19) 14.2.0`; no `CC` override and no shim were used.

- `make -C vendor/spinel deps`: exit 0.
- `make -C vendor/spinel -j8`: exit 0.
- Compiled and executed `puts 6 * 7`: output `42`, exit 0.
- `make -C vendor/spinel -j8 test` under `umask 002`: exit 2, summary `Tests: 3542 pass, 1 fail, 0 error`. The one failure was `implicit_conversion_protocol`, differing from its expectation on a single line: mode `644` expected, `664` observed.
- The same target under `umask 022`: exit 0, summary `Tests: 3543 pass, 0 fail, 0 error`.

The failure was attributed by running one already-built test binary under both umask values: byte-identical to the expectation under `umask 022`, one differing line under `umask 002`. It is a property of the environment rather than a defect in the pinned compiler, and it is why [Building and testing](building.md) requires `umask 022`.

### Not covered by this baseline

The benchmark suite, optcarrot, and other non-test targets were not run on any host. The core/full acceptance criteria are defined in [roadmap](roadmap.md); what is missing is their implementation and verification.

At the time of this baseline the repository had no Extended driver, no tier tests and no CI configuration, and nothing from the predecessor had been imported, so nothing in this section meets or checks those criteria. That is still true of this section; the core slice recorded above changes part of it, and its own scope and limits are stated there. The project-wide license for original Extended contributions remains undecided.

## Native core compiler pin (2026-09-11)

Spinel is advanced from `5bc45ec19a372c6f4da29485a7ce35c81b9751cc` to
`cad0ad148af00b98a3de8a384c18a3cabe15bc1a` from `yuskesh/spinel`,
`core/input-ledger`. The latter contains the reviewed selected-root seam
(`00218233`) and the opt-in frontend input ledger. The fork default branch
is unchanged. These additions preserve inference, numeric/nil representation,
GC and arena semantics; the new internal linkage contract names selected roots,
retains their inferred signatures and omits their hosted definitions.

The Extended driver checks input ledgers, mapping signatures and the emitted
object before linking. macOS adaptation selects SDK libc++ headers, LLVM nm
with Mach-O symbol normalization, the platform checksum utility, and the native
link libraries. It changes no Ruby semantics or public numeric ABI.

See [reproduction and revision-scoped evidence](native-core/reproducing.md),
[Mac validation](native-core/macos-validation.md), and the existing source-path
records for the imported MLIR scalar components. No predecessor checkout is a
build dependency. Existing upstream notices and the unresolved project-wide
licence status are retained. No licence is inferred by this pin update.

## DOOM hosted import (2026-09-11)

Decision [0006](decisions/0006-doom-hosted-import.md), task 2. The owner's
acceptance of GPL-derived files in `examples/doom/` and `tests/doom/` was given
with the original implementation handover; decision 0006 is accepted for
implementation.

- **Source revision:** `spinel-llvm` at
  `f8ad13c6d9dc990b116ba1c842c7881232f29585`, read-only. Files were read through
  `git show`; that checkout was not modified.
- **Original paths and local paths:** recorded per file in
  `tests/doom/manifest.tsv`, which carries the original path, byte length and
  SHA-256 **and** the local path, byte length and SHA-256 of every file, plus a
  `modified` column. A file changed on import is therefore distinguishable by
  machine from one that was not.
- **Local changes:** five files, seven lines. Each test program's
  `require_relative` prefix was rewritten from `../lib/doom/…` to
  `../../../examples/doom/lib/doom/…`, because the library and the tests are in
  different directories here. The other 41 files, and all five `.expected`
  files, are byte-identical to their originals.
- **Notices:** `examples/doom/LICENSE` carries the GNU General Public License
  version 2; `examples/doom/NOTICE.md` and `tests/doom/NOTICE.md` record the
  origin, quote the statements the sources make about their own derivation, and
  assert no authorship or copyright holder beyond what the sources state. The
  predecessor's `doom/` tree carried no `LICENSE` or `COPYING`, so the licence
  file was added on import rather than preserved; that is stated in the notice.
  Two imported files carry their own derivation statement in their headers —
  `lib/doom/info.rb` and `lib/doom/tables.rb` say their tables are emitted
  mechanically from id Software's `info.c` / `tables.c`, described there as
  GPL-2.0-or-later — and those headers are preserved verbatim.

### What the manifest contains, and how it was derived

46 files, computed from the `require_relative` closure rather than listed by
hand: 3 entry points, 33 library files, 5 test programs, 5 expectations.

The union of the three entry closures is **34 files**, which reproduces Task 1's
figure (`doom.rb` 32, `sim_demo.rb` 28, `record_demo.rb` 29). The five probe
closures add `palette.rb`, `picture.rb` and the probe programs themselves,
giving 41, and each probe's combined-stream expectation brings it to 46.

One correction to Task 1's record: the expectation files are named
`<name>.expected`, not `<name>.rb.expected`. The manifest uses the real names.

The five probes need no data fixture. `wad_and_picture` takes an optional
scratch directory as `ARGV[0]` and writes its own synthetic WAD; the other four
read nothing.

### No dependency on the predecessor checkout

`tools/doom/verify-sources.sh` checks the imported tree against the manifest in
both directions — every declared file present at its recorded local digest, and
every file under the imported directories declared — and reads nothing outside
this checkout. It takes no source path and has no fallback. `tests/doom/run.sh`
calls it before compiling anything.

`tools/doom/audit-origin.sh` re-derives the *original* digests from a read-only
predecessor checkout named by `DOOM_SRC_GIT`. It is an audit: neither the build
nor the test suite calls it, so the predecessor is not a build dependency.

### Reproduction

From a clean checkout, in this order — `make deps` comes first because the
compiler will not build without Prism (`docs/building.md:45`):

```sh
git submodule update --init --recursive
make -C vendor/spinel deps
make -C vendor/spinel -j"$(nproc)"
LLVM_PREFIX=/opt/llvm-23.1.1 RUBY=ruby tests/doom/run.sh
LLVM_PREFIX=/opt/llvm-23.1.1 RUBY=ruby tests/doom/negative-controls.sh
```

No second repository is needed. Optionally, to audit the origin:

```sh
DOOM_SRC_GIT=/path/to/spinel-llvm tools/doom/audit-origin.sh
```

Recorded on Debian x86_64 with `spinel cad0ad148af0`, Clang 23.1.1 and
`ruby 3.3.8`:

```
verify-sources: 46 imported files verified (5 changed on import)
doom-tests: 5 run, 5 pass, 0 fail                       exit 0
negative-controls: 8 run, 8 pass, 0 fail                exit 0
audit-origin: 46 originals re-derived; 41 byte-identical to the import, 5 changed
```

The IWAD itself is never committed; `tools/doom/fetch-iwad.sh` fetches it into
an untracked directory with its length and SHA-256 checked before publication.

## DOOM capability extractions (2026-09-12)

Decision [0007](decisions/0007-doom-core-preparation.md), task 5. Thirteen Ruby
entries under `tests/core-boundary/fixtures/{capabilities,framebuffer,slots}/src/`
are **copied and adapted from `examples/doom/lib/doom/`**, which is GPL-derived,
so they are GPL-derived too and carry the same licence.

- **Originals:** `fixed.rb` (the fixed-point helpers and the angle
  normalisation), `executor.rb` (the wall column, the plane span, the fuzz
  column) and `game.rb` (the thinker list and the mobj slot allocator). Their
  own import — source repository, source revision, per-file digests — is
  recorded in the section above and in `examples/doom/NOTICE.md`.
- **Per-file record:** each of the three directories carries a
  `provenance.tsv` giving, for every extracted file, the original path and the
  upstream C function the Full source attributes it to. Each extracted source
  also names its origin in its own header.
- **Local changes:** each source lists every adaptation it makes, in the
  source. They are spelling changes within the checked subset, with one
  exception marked as such: `slots/src/thinker_collect.rb` bounds a walk the
  original does not bound, so a cyclic list answers `SPINEL_CORE_CAPACITY`
  instead of not answering.
- **Notices:** `tests/core-boundary/fixtures/NOTICE.md`.
- **Reproduction:** `tests/core-boundary/capabilities.sh`,
  `framebuffer.sh` and `slots.sh` each run the ORIGINAL Full code and the
  extraction over the same inputs and require them to agree, so the
  relationship between the two is checked rather than asserted. The provenance
  tables and the in-source attributions are checked by the same lanes.

Nothing else under `tests/core-boundary/fixtures/` is derived from DOOM.
`closure/census.rb` reads the Full tree to count what is in it and copies none
of it.

## DOOM reference patches for doomgeneric (2026-09-11)

Recorded here on 2026-10-23 from [`tests/doom/reference/NOTICE.md`](../tests/doom/reference/NOTICE.md)
and [`tests/doom/reference/manifest.tsv`](../tests/doom/reference/manifest.tsv); imported in
commit `f610f99`.

- **Source repository:** `spinel-llvm`, the predecessor project, at
  `f8ad13c6d9dc990b116ba1c842c7881232f29585`, read from Git objects with
  `git show`; that checkout was not modified.
- **Imported paths:** six patches, `tests/doom/reference/patches/0{1..6}-*.patch`,
  and the frame golden `tests/doom/fixtures/reference/demo1_hashes.tsv`. The
  manifest gives each original path, byte length and SHA-256 beside the local
  ones. Every file is byte-identical to its original; the local names add only
  the application order.
- **What they modify:** C source from
  [ozkl/doomgeneric](https://github.com/ozkl/doomgeneric), a Chocolate Doom
  derivative of id Software's DOOM source release; the patches apply to
  doomgeneric at `dcb7a8dbc7a16ce3dda29382ac9aae9d77d21284`, which is not
  tracked here.
- **Licence:** GPL-derived, redistributed under the GNU General Public License,
  version 2, whose text is `tests/doom/reference/LICENSE`. This is a separate
  provenance from `examples/doom/`, with its own notice.

## Spinel fork reproducers (2026-09-12)

Recorded here on 2026-10-23 from
[`tests/doom-core/fork/fixtures/NOTICE.md`](../tests/doom-core/fork/fixtures/NOTICE.md);
imported in commit `f403beb`.

- **Source repository:** the predecessor's spinel-fork, mirrored as branch
  [`spinel-fork/c-emit-ir`](https://github.com/yuskesh/spinel/tree/spinel-fork/c-emit-ir) of `yuskesh/spinel`,
  at `ecbd0f2a7cd134d5affc2bd705f0f0e83aa82101`, under `test/`.
- **Imported paths:** eleven programs and their expected outputs,
  `tests/doom-core/fork/fixtures/*.rb` and `*.rb.expected`, copied unchanged;
  the byte digests in `tests/doom-core/fork/ledger.tsv` are the check.
- **Licence:** the fork is a fork of Spinel, MIT, copyright Yukihiro Matsumoto;
  the notice reproduces the licence text, whose full text is `LICENSE` at that
  revision.

## Decision 0007 stage-1 results, Debian (2026-09-12)

Task 6's second bullet. Recorded from the runs themselves; no figure here is
carried over from an earlier one, and the clean-checkout build is distinguished
from the incremental one.

| | |
|---|---|
| branch | `feat/doom-core-preparation` |
| commit | `57bcc74e32ae945fa59975a77d3b3762cdfe85a1` |
| submodule pin | `cad0ad148af00b98a3de8a384c18a3cabe15bc1a` |
| host | Debian GNU/Linux 13 (trixie) x86_64 |
| C toolchain | clang 23.1.1 (llvm-project 6dfe1677ab8dffbc6ec13d53a1e0215d75147689), `LLVM_PREFIX=/opt/llvm-23.1.1` |
| ruby | 3.3.8 (2025-04-09 revision b200bad6cd) |

### The documented build, from a clean checkout

Run at `f08a976`, the commit before the angle-normalisation extraction, in a
fresh `git clone` of this repository with its own dependency download — not the
working tree, and not a reused `vendor/spinel`. Every step exited 0:

```sh
git clone <this repository> checkout && cd checkout
git submodule update --init --recursive
make -C vendor/spinel deps
make -C vendor/spinel -j8
printf 'puts 6 * 7\n' > build/hello.rb
vendor/spinel/spinel build/hello.rb -o build/hello && ./build/hello   # 42
sh tools/contract/build.sh
LLVM_PREFIX=/opt/llvm-23.1.1 sh tools/mlir/native/build.sh
sh tests/core-boundary/run.sh
```

The last line answered `core-boundary: 9 lanes, 9 passed, 0 failed, 0 could not
run`.

### The new suite

`sh tests/core-boundary/run.sh`, at the commit in the table above, on an
incremental native build:

| lane | result |
|---|---|
| `schema` | 73 checked, 73 pass, 0 fail |
| `arithmetic` | 171 checked, 171 pass, 0 fail, 66/66 executed |
| `buffers` | 115 checked, 115 pass, 0 fail, 53/53 executed, 2 sanitisers run |
| `adapter` | 62 checked, 62 pass, 0 fail, 45/45 executed |
| `capabilities` | 49 checked, 49 pass, 0 fail |
| `framebuffer` | 22 checked, 22 pass, 0 fail |
| `slots` | 24 checked, 24 pass, 0 fail |
| `artifacts` | 30 checked, 30 pass, 0 fail, 13 entries over 3 capabilities |
| `closure` | 32 checked, 32 pass, 0 fail, 27 constructs probed |

### The affected existing checks

| check | command | result |
|---|---|---|
| core eligibility | `python3 tests/core-eligibility/run.py` | OK, 50 tests |
| core acceptance | `SPINEL_CORE_BUILD=tools/mlir/native/build sh tests/core/run.sh` | 33 passed, 0 failed |
| native CORE driver | `sh tests/native-core/driver.sh` | exit 0 |
| native CORE ledger | `sh tests/native-core/ledger.sh` | exit 0 |
| native CORE run | `sh tests/native-core/run.sh` | exit 0 |
| hosted DOOM | `LLVM_PREFIX=/opt/llvm-23.1.1 RUBY=ruby sh tests/doom/run.sh` | 5 run, 5 pass, 0 fail |

### What these results do not establish

macOS. Decision 0007 requires that macOS independently build and run the new
boundary tests, and Debian results do not close that criterion. The macOS runs
recorded during implementation were on incremental native builds reusing an
existing contract reader and the pinned binary, which is not a clean dependency
build.

Performance is not measured here. The decision puts it after correctness and
requires copying cost to be reported rather than hidden in kernel-only timings;
neither has been done, and no timing is claimed.

## Decision 0007 stage-1 results, macOS (2026-09-12)

Task 6's third bullet. Current measured behaviour is stated first. The earlier
reading of the same day is kept below it, labelled as history, together with
what was wrong with it; no evidence is removed.

### Re-measured from a clean checkout with the documented compiler (2026-09-12)

| | |
|---|---|
| commit | `20e6b79` |
| submodule pin | `cad0ad148af00b98a3de8a384c18a3cabe15bc1a` |
| host | macOS arm64, Darwin 25.6.0 |
| C toolchain | `clang version 23.1.1` (`llvm-project 6dfe1677ab8dffbc6ec13d53a1e0215d75147689`), prefix `$HOME/.local/opt/llvm-23.1.1` |
| ruby | `ruby 3.4.1 (2024-12-25 revision 48d4efcb85) +PRISM [arm64-darwin23]` |

The checkout is a fresh `git clone` of this repository into a scratch
directory, `git checkout 20e6b79`, and `git submodule update --init
--recursive` with the submodule URL pointed at the local `vendor/spinel` clone
(`-c protocol.file.allow=always`), which checked out the pinned
`cad0ad148af00b98a3de8a384c18a3cabe15bc1a`. Nothing was reused from an earlier
build tree.

Build, with `umask 022` and `NO_CCACHE=1` because `ccache` is on this machine's
`PATH`, each step exiting 0:

```sh
export LLVM_PREFIX=$HOME/.local/opt/llvm-23.1.1
make -C vendor/spinel deps
make -C vendor/spinel -j8 CC="$LLVM_PREFIX/bin/clang"
CC="$LLVM_PREFIX/bin/clang" sh tools/contract/build.sh
LLVM_PREFIX="$LLVM_PREFIX" sh tools/mlir/native/build.sh
```

**Which compiler built this vendor tree, checked rather than assumed.**
`make -C vendor/spinel -p -n CC="$LLVM_PREFIX/bin/clang" | grep '^CC_KIND'`
prints `CC_KIND := clang` with `CC = /Users/<user>/.local/opt/llvm-23.1.1/bin/clang` (user name elided).
`vendor/spinel/build/sp_str.o` is 142600 bytes and is BYTE-IDENTICAL to an
object compiled separately from the same source with LLVM 23.1.1; the Apple
clang 21 build of that same file is 150872 bytes and differs.
`vendor/spinel/lib/libspinel_rt.a` is 1173336 bytes, the LLVM 23.1.1 size,
against 1192880 for the Apple clang build. `otool -l vendor/spinel/spinel |
grep -A4 LC_BUILD_VERSION` reports `platform 1`, `minos 26.0`, `sdk 26.5`.
The `build/pch/` directory that `docs/building.md` describes is not produced on
this platform at this revision, so that particular check could not be applied;
the byte-exact object comparison stands in for it and is stronger.

The suites were run with `RUBY=ruby`, `SPINEL=$PWD/vendor/spinel/bin/spinel`,
`SPINEL_SEAM=$PWD/vendor/spinel`,
`SPINEL_CORE_BUILD=$PWD/tools/mlir/native/build`,
`CLANG=$LLVM_PREFIX/bin/clang`, `CC=$CLANG` and `NM=$LLVM_PREFIX/bin/llvm-nm`
exported.

| check | result | exit |
|---|---|---|
| `REQUIRE_ALL=1 tests/core-boundary/run.sh` | `core-boundary: 9 lanes, 9 passed, 0 failed, 0 could not run` | 0 |
| `tests/doom/run.sh` | `doom-tests: 5 run, 5 pass, 0 fail` | 0 |
| `python3 tests/core-eligibility/run.py` | `Ran 50 tests in 1.574s` / `OK` | 0 |
| `tests/native-core/driver.sh` | `core driver: 43 passed, 0 failed` | 0 |
| `tests/native-core/ledger.sh` | `input ledger: 23 passed, 0 failed` | 0 |
| `python3 tests/native-core/macos-probe.py` | `PASS: 9 native fixtures, exports/undefined checks, stub routing, missing body, sentinel refusal` | 0 |
| `tests/native-core/run.sh` | `native core: 5 passed, 11 failed` — Linux-only, see below | 1 |
| `tests/core/run.sh` | `core acceptance: 21 passed, 12 failed` — no arm64 profile, see below | 1 |

The nine lanes, verbatim:

```
  ok       schema: 73 checked, 73 pass, 0 fail
  ok       arithmetic: 171 checked, 171 pass, 0 fail (the oracle lane is 99 checks of its own), 66/66 executed
  ok       buffers: 115 checked, 115 pass, 0 fail, 53/53 executed, 0 refusal(s) pre-empted, 2 sanitiser(s) run
  ok       adapter: 62 checked, 62 pass, 0 fail, 45/45 executed, 0 not applicable here, 0 lane(s) unmeasured
  ok       capabilities: 49 checked, 49 pass, 0 fail
  ok       framebuffer: 22 checked, 22 pass, 0 fail
  ok       slots: 24 checked, 24 pass, 0 fail
  ok       artifacts: 30 checked, 30 pass, 0 fail, 13 entries over 3 capabilities
  ok       closure: 32 checked, 32 pass, 0 fail, 27 construct(s) probed
```

Limits of this run. It is one machine, one LLVM installation and one Ruby. It
says nothing about the upstream `make test` corpus, which was not run here, and
nothing about performance, which is still unmeasured. `tests/core/run.sh` still
has no arm64 freestanding profile to run against, so the declared freestanding
leg remains unexercised on macOS.

### The driver and ledger failures were an environment omission

`tools/core/core-artifact-gate` line 26 reads
`NM_="${NM:-${LLVM_PREFIX:?set LLVM_PREFIX or NM}/bin/llvm-nm}"` on Darwin: with
neither variable set the gate refuses to start. All four `driver.sh` failures
are that refusal, each printing `LLVM_PREFIX: set LLVM_PREFIX or NM`.
`tests/native-core/ledger.sh` line 96 passes
`--clang "${CLANG:-/opt/llvm-23.1.1/bin/clang}"`, a Debian path that does not
exist on macOS, which is the single `ledger.sh` failure.

This is measured on the same clean tree described above, not argued. With the
variables unset and nothing else changed:

```
core driver: 39 passed, 4 failed
input ledger: 22 passed, 1 failed
```

and with `LLVM_PREFIX`, `CLANG`, `CC` and `NM` exported, 43/0 and 23/0. Same
commit, same build, same machine: the variables are the entire difference. The
2026-09-11 record reproduced because the command block in
`docs/native-core/reproducing.md` exports `CLANG`, `CC` and `NM`. Those
variables are now stated as required on macOS in that page and in the two
scripts' header comments.

### `tests/native-core/run.sh` is ELF-only, and was misattributed

`tests/native-core/run.sh` is not a macOS check and its own header says so: "it
does NOT establish anything about macOS or Mach-O". Two things in it are Linux
assumptions rather than failures. Lines 75, 115 and 153 link with `-lcrypt`,
and macOS has no such library — `clang x.c -lm -lcrypt` answers `ld: library
'crypt' not found` — which is the nine `builds end to end` cases and the
`stub-core control links` case. The remaining failure, `the core object exports
exactly the mapped symbol`, reports `saw [_spc_s_lower_lower]`: the Mach-O
leading underscore is not normalised away before the comparison. Its macOS
counterpart is `tests/native-core/macos-probe.py`, which does the same nine
fixtures with the underscore handled and the runtime linked without `-lcrypt`,
and it passes.

The earlier table in this section put "nine fixtures matched CRuby" in the
`tests/native-core/run.sh` row of the 2026-09-11 column. That is a
misattribution: `docs/native-core/macos-validation.md` records that line under
"Native Mach-O probe", which is `macos-probe.py`. `tests/native-core/run.sh`
has never been recorded as passing on macOS and is not expected to.

That describes the suite at `20e6b79`. The hardening recorded at the end of
this file made it Darwin-aware, and it passes on macOS since.

### `tests/core/run.sh` is a platform gap, unchanged

`tests/core/run.sh` line 82 hard-codes
`tools/freestanding/profiles/x86_64-linux-host.yaml`, whose `target.triple` is
`x86_64-unknown-linux-gnu`, and `tools/freestanding/profiles/` holds only that
profile and a Cortex-M33 one — there is no arm64 profile at all. On macOS arm64
the freestanding emitter therefore produces an object for x86_64 Linux and the
linker answers `ld: unknown file type in 'k32.o'` and `'k64.o'`. That line has
not changed since the original import at `7d1dfee`, and
`docs/native-core/macos-validation.md` never covered this suite: its four items
are the product driver, the input ledger, source eligibility and the native
Mach-O probe. So there is no record of the suite ever passing on macOS, and
none is implied here.

That there is no way to exercise the freestanding leg on macOS is stage-2
design input. It is not something this decision's work created.

### Historical: what was recorded earlier on 2026-09-12, and why it was wrong

Kept because the measurements were real and the reasoning is on record.

macOS verified the branch twice: at `e75ce75`, the commit of the formal
handoff, and again at `2112771`, its final commit, after the
angle-normalisation extraction and the documentation that followed. The second
run repeated the first — build exit 0, `capabilities.sh` 49 of 49, and
`REQUIRE_ALL=1 tests/core-boundary/run.sh` nine lanes of nine: schema 73,
arithmetic 171, buffers 115, adapter 62, capabilities 49, framebuffer 22,
slots 24, artifacts 30, closure 32 — on Ruby 3.4.1 with Prism and LLVM 23.1.1.
Those nine-lane results are confirmed by the re-measurement above and stand.

The detail below is from the `e75ce75` run, in a worktree at
`.worktrees/core-boundary-mac`, where the legacy suites were measured.

| | |
|---|---|
| commit | `e75ce751ddf5b81efe59071670a10672d952d9f2` |
| submodule pin | `cad0ad148af00b98a3de8a384c18a3cabe15bc1a` |
| host | macOS arm64 |
| C toolchain | recorded as clang 23.1.1; **actually Apple clang 21 for the vendor build**, see below |
| ruby | 3.4.1, with Prism |

**That run's "clean dependency build" did not use the documented compiler.**
`docs/building.md` requires `make -C vendor/spinel -j8 CC="$LLVM_PREFIX/bin/clang"`;
the worktree was built with a bare `make`, which on macOS resolves `cc` to
Apple clang. Recompiling `lib/sp_str.c` from that tree byte-exactly settles it:
150872 bytes with Apple clang 21 against 142600 with LLVM 23.1.1, and the
worktree's object is the 150872-byte one. The main checkout's vendor tree is
the LLVM 23 build. Apple-built archives are readable and linkable by LLVM 23
tools, so this is not what produced the failures below; it does mean the
recorded macOS stage-1 evidence was taken against a hosted compiler binary
built by the wrong compiler, which is why it has been re-measured rather than
re-explained.

What that run recorded, and what each row actually was:

| check | recorded at `e75ce75` | recorded for macOS on 2026-09-11 | now explained as |
|---|---|---|---|
| `tests/core/run.sh` | link failed, Mach-O `k32.o` unknown file type | not in that record | missing arm64 freestanding profile; never claimed on macOS |
| `tests/native-core/driver.sh` | 39 passed, 4 failed | 43 passed, 0 failed | `LLVM_PREFIX`/`NM` unset; the gate refused to start |
| `tests/native-core/ledger.sh` | 22 passed, 1 failed | 23 passed, 0 failed | `CLANG` unset; the Debian fallback path does not exist here |
| `tests/native-core/run.sh` | 5 passed, 11 failed | *(not recorded; the 2026-09-11 "nine fixtures matched CRuby" is `macos-probe.py`)* | ELF-only suite: `-lcrypt`, and no underscore normalisation |

The reasoning built on those rows was that the same content at `1435713`
produced different results on two days, so the cause had to be outside the
repository, and that no external candidate — SDK 26.5, Xcode 26.6 with
ld-1267, the clang configuration file, the triple, a stale build directory —
survived measurement. Every one of those candidates was in fact correctly
excluded. The deduction was sound and its premise was not: the two days
differed in the exported environment, not in the machine. What was recorded as
"three macOS legacy checks disagree with this repository's own record, and why
is unknown" is closed.

Also on record from that investigation, and still true: rebuilding the native
tools on **Debian** with this branch's one change to `Eligibility.cpp` reverted
and running all four suites against both builds produces identical output — the
only difference is a temporary directory's name — with the driver at 43 and the
ledger at 23. `spinel-core-emit` does link the library that changed, so the
possibility was real and was tested rather than argued away.

`docs/native-core/macos-validation.md` remains marked historical, because its
numbers are tied to the 2026-09-11 run and its toolchain, not because it was
found to be wrong.

### What this settles for decision 0007

macOS built commit `20e6b79` from a clean checkout with the documented
compiler, verified which compiler produced the vendor tree, and ran all nine
new lanes under `REQUIRE_ALL=1` plus `tests/doom/run.sh`, core eligibility, the
product driver, the input ledger and the Mach-O probe — all passing. Of the two
suites that did not pass at that commit, `tests/native-core/run.sh` was an
ELF-only suite that had never applied to macOS and has since been made
Darwin-aware, and `tests/core/run.sh` cannot run without an arm64 freestanding
profile. Neither is a regression, and nothing on this point is open.

## Test hardening after the stage-1 review, macOS (2026-09-12)

Measured in the working tree of branch `fix/stage1-review-findings`, based on
`20e6b79`, on the same host and toolchain as the re-measurement above (LLVM
23.1.1 at `LLVM_PREFIX`, ruby 3.4.1, `LLVM_PREFIX`, `CLANG`, `CC`, `NM`,
`RUBY`, `SPINEL`, `SPINEL_SEAM` and `SPINEL_CORE_BUILD` exported). The commit
that carries these changes is recorded at integration.

What changed, and why each is a stronger check rather than a different one:

- `framebuffer.sh` and `slots.sh` now require the oracle's own verdict line and
  the intended failure text before a control counts as caught. A corrupted
  `scene.rb`/`trace.rb` previously left both lanes at full pass; it now fails
  10 and 11 controls with "never reached its comparison".
- `capabilities.sh`, `framebuffer.sh` and `slots.sh` check the SHA-256 of each
  original under `examples/doom/lib/doom/` against `originals.tsv`, so drift of
  an original is a named failure. This is one new check per lane.
- `artifacts.sh` runs the direct slots harness in refuse mode and compares its
  cells, instead of counting rows of `trace.tsv`; `closure.sh` keeps its row
  check, relabelled as a declaration check.
- `REQUIRE_ALL=1` now fails `adapter.sh` and `buffers.sh` when a sub-lane could
  not run for want of a tool (no TSan, no pinned compiler, no sanitiser); the
  UBSan case that no toolchain closes stays a labelled note. Counts are
  deliberately unchanged so machines stay comparable.
- `tests/native-core/ledger.sh` refuses when `CLANG` is unset and `LLVM_PREFIX`
  supplies no clang, instead of falling back to a Debian path.
- `tests/native-core/run.sh` drops `-lcrypt` on Darwin and strips one Mach-O
  leading underscore before its symbol comparisons, so it applies to macOS.
- `fixtures/closure/census.rb` counts accessor call sites (`attr_sites`, 69)
  and `closure.sh` holds that figure too.

Results, verbatim:

```
  ok       schema: 73 checked, 73 pass, 0 fail
  ok       arithmetic: 171 checked, 171 pass, 0 fail (the oracle lane is 99 checks of its own), 66/66 executed
  ok       buffers: 115 checked, 115 pass, 0 fail, 53/53 executed, 0 refusal(s) pre-empted, 2 sanitiser(s) run
  ok       adapter: 62 checked, 62 pass, 0 fail, 45/45 executed, 0 not applicable here, 0 lane(s) unmeasured
  ok       capabilities: 50 checked, 50 pass, 0 fail
  ok       framebuffer: 23 checked, 23 pass, 0 fail
  ok       slots: 25 checked, 25 pass, 0 fail
  ok       artifacts: 30 checked, 30 pass, 0 fail, 13 entries over 3 capabilities
  ok       closure: 32 checked, 32 pass, 0 fail, 27 construct(s) probed
core-boundary: 9 lanes, 9 passed, 0 failed, 0 could not run
core driver: 43 passed, 0 failed
input ledger: 23 passed, 0 failed
native core: 18 passed, 0 failed
PASS: 9 native fixtures, exports/undefined checks, stub routing, missing body, sentinel refusal
```

Three counts moved, each by the one digest check named above: capabilities
49 to 50, framebuffer 22 to 23, slots 24 to 25. At the time of this macOS run,
Debian had not rerun the hardened lanes; the earlier Debian figures are the
counts at `57bcc74`. The subsequent Debian run below measures the hardened
lanes and matches these macOS counts.

### Debian, the same branch, documented toolchain (2026-09-12)

Measured in a clean worktree of `fix/stage1-review-findings` at `17cfc72`, on
Debian GNU/Linux 13 (trixie) x86_64, ruby 3.3.8, `umask 022`, the submodule at
its pin `cad0ad148af00b98a3de8a384c18a3cabe15bc1a`, unchanged.

`vendor/spinel` was rebuilt by the block in `docs/building.md`, all three of
whose paths were pointed at LLVM 23.1.1: a shim directory first on `PATH` so
that `cc` resolves to `/opt/llvm-23.1.1/bin/clang`, `make clean` before
building, `CC="$LLVM_PREFIX/bin/clang"` on the command line, and both
`NO_CCACHE=1` and an empty `CCACHE_DIR` — `ccache` is installed on this host
and `common.mk` prepends it with `override`, so a cache hit could otherwise
have replayed an object this toolchain did not produce.

Verified before the suites ran:

```
$ cc --version | head -1
clang version 23.1.1 (https://github.com/llvm/llvm-project 6dfe1677ab8dffbc6ec13d53a1e0215d75147689)
$ vendor/spinel/bin/spinel --version
spinel cad0ad148af0 (unreleased) [clang version 23.1.1 (...6dfe1677ab8dffbc6ec13d53a1e0215d75147689)]
```

`build/csrc/*.o`: 0 of 22 carry a GCC `.comment`. `build/libprism.a`,
`build/librbs.a` and `lib/libspinel_rt.a` are clang 23.1.1 throughout.

The executable itself carries both `GCC: (Debian 14.2.0-19) 14.2.0` and
`clang version 23.1.1`, and that is expected rather than a mixed build: Debian's
clang links GCC's `crtbeginS.o` and `crtendS.o`, whose own `.comment` is the
GCC string. Every translation unit is clang's.

Commands, in the order run:

```sh
REQUIRE_ALL=1 sh tests/core-boundary/run.sh
sh tests/native-core/driver.sh
sh tests/native-core/ledger.sh
sh tests/native-core/run.sh
LLVM_PREFIX=/opt/llvm-23.1.1 RUBY=ruby sh tests/doom/run.sh
env -u CLANG -u LLVM_PREFIX sh tests/native-core/ledger.sh
python3 tests/core-eligibility/run.py
SPINEL_CORE_BUILD=tools/mlir/native/build sh tests/core/run.sh
```

Summary lines, verbatim:

```
  ok       schema: 73 checked, 73 pass, 0 fail
  ok       arithmetic: 171 checked, 171 pass, 0 fail (the oracle lane is 99 checks of its own), 66/66 executed
  ok       buffers: 115 checked, 115 pass, 0 fail, 53/53 executed, 0 refusal(s) pre-empted, 2 sanitiser(s) run
  ok       adapter: 62 checked, 62 pass, 0 fail, 45/45 executed, 0 not applicable here, 0 lane(s) unmeasured
  ok       capabilities: 50 checked, 50 pass, 0 fail
  ok       framebuffer: 23 checked, 23 pass, 0 fail
  ok       slots: 25 checked, 25 pass, 0 fail
  ok       artifacts: 30 checked, 30 pass, 0 fail, 13 entries over 3 capabilities
  ok       closure: 32 checked, 32 pass, 0 fail, 27 construct(s) probed
core-boundary: 9 lanes, 9 passed, 0 failed, 0 could not run
```

```
core driver: 43 passed, 0 failed
input ledger: 23 passed, 0 failed
native core: 18 passed, 0 failed
doom-tests: 5 run, 5 pass, 0 fail
core acceptance: 33 passed, 0 failed
```

`python3 tests/core-eligibility/run.py` answered `OK`, exit 0.

The three counts the hardening moved are the three that moved here, and the
other six are unchanged: capabilities 50, framebuffer 23, slots 25, against
schema 73, arithmetic 171 with 66 of 66, buffers 115 with 53 of 53 and both
sanitisers, adapter 62 with 45 of 45, artifacts 30 over 13 entries, closure 32
over 27 constructs. macOS and Debian agree line for line on all nine lanes.
`tests/native-core/run.sh`'s Darwin guards did not change its Linux behaviour.

The control refuses as intended:

```
$ env -u CLANG -u LLVM_PREFIX sh tests/native-core/ledger.sh
ledger.sh: set CLANG to the clang this build used, or LLVM_PREFIX to its prefix
```

exit 2, nothing run. `/opt/llvm-23.1.1` exists on this host, so the removed
fallback is not being reached by another route either.

### Historical: the first Debian run, and what was wrong with its record

Kept because the measurements were real. The numbers are the same; two claims
made about the build that produced them were not.

That run built `vendor/spinel` with `CC="$LLVM_PREFIX/bin/clang"` but without
the rest of the documented block: no shim directory, so `cc` resolved to
`/usr/bin/cc`, and no `NO_CCACHE=1` or empty `CCACHE_DIR` although `ccache` is
installed here. It reported the same counts as the run above — nine lanes of
nine, driver 43, ledger 23, native core 18, DOOM 5 of 5, core acceptance 33.

Two things were then recorded about it, and one of them was wrong.

**Wrong: "the pinned binary is a mixed build".** It is not. Asked properly —
`llvm-readelf --string-dump=.comment` per object rather than `strings` over the
executable — 0 of 22 objects under `build/csrc/`, and none in `libprism.a`,
`librbs.a` or `libspinel_rt.a`, carry a GCC comment. The GCC string in the
executable comes from Debian's `crtbeginS.o` and `crtendS.o`, which clang links
by default here; it appears in every clang-built binary on this platform and
says nothing about which compiler compiled the sources. The earlier note
conflated a linked CRT with a compiled translation unit.

**Right: `spinel --version` reported `cc (Debian 14.2.0-19) 14.2.0`.** That is
the `cc` the compiler executes for itself, and without the shim it was the
system GCC. `adapter.sh` drives the pinned compiler to build the generated Ruby
module, so its 62 of 62 in that run was not a result under the documented
toolchain. It is under the one above, and the count is the same.

#### What that run's record said, verbatim

Kept so the correction above has something to correct.

- **The pinned binary is a mixed build.** `CC=$LLVM_PREFIX/bin/clang` was given
  on the make command line and clang 23.1.1 did compile part of the tree --
  `vendor/spinel/bin/spinel` carries that clang's version string -- but the
  binary also carries `GCC: (Debian 14.2.0-19) 14.2.0`, so some objects were
  compiled by the system GCC, which a command-line `CC=` did not reach.
- **`spinel --version` reports `cc (Debian 14.2.0-19) 14.2.0` here**, where
  earlier Debian runs recorded in this file reported `clang version 23.1.1`.
  That bracket is the `cc` the compiler will execute for itself, which
  `docs/building.md` records as a hardcoded command name, and
  `/opt/llvm-23.1.1/bin` was not on the running shell's PATH, so it resolved to
  `/usr/bin/cc`. The only lane that drives the pinned compiler is `adapter.sh`,
  which passed 62 of 62 with 45 of 45 executed.

Whether either should be tightened is not decided here; they are stated so that
a later disagreement between two machines has one less unrecorded variable.

## Freestanding target profiles and lanes (2026-09-23)

- Source repository: spinel-llvm (a private predecessor repository), revision
  `463d49dd` (read-only; not modified).
- Adoption date: 2026-09-23. Imported as one batch, under the migration rules
  on `main` at `d39b5bf`.
- License: as for the native core slice above -- the source repository states
  none, and the question is the same one.
- Notices: none beyond the source's. The Zephyr applications under
  `tests/freestanding/*/zephyr/` build against Zephyr (Apache-2.0) but contain
  no Zephyr source.

| Original | Local |
|---|---|
| `tools/freestanding/profiles/{riscv32-zephyr,wasm32-worker,workers-wasm32,zephyr-cortex-m33,zephyr-riscv32}.yaml` | `tools/freestanding/profiles/` |
| `tools/platform/menus.yaml` | `tools/platform/menus.yaml` |
| `docs/experiments/results/E040/{e040_kern.rb,mkcases.rb,zephyr/**}` and its runners | `tests/freestanding/e040/` |
| `docs/experiments/results/E063/{run_node,trap_probe,wasm_shape,worker_probe}.mjs`, `mkcases_wasm.rb`, `mksig.rb`, `probe/{index.mjs,wrangler.toml}` and its runners | `tests/freestanding/e063/` |
| `docs/experiments/results/E077/{e077_kern.rb,cases.json,expect.tsv,arm64-none.yaml,*.mjs,zephyr/**}` and its runners | `tests/freestanding/e077/` |
| `docs/experiments/results/E081/{e081_kern.rb,cases.json,expect.tsv,*-e081.yaml,*.mjs,goodwrapper_plain.c,badwrappers/*,reject/*,zephyr/**}` and its runners | `tests/freestanding/e081/` |
| `docs/experiments/results/E083/{run_reject.sh,reject/*,cortex-m33-zephyr-e083.yaml}` | `tests/freestanding/e083/` |
| `docs/experiments/results/E166/cp5b/mkcases_inc.rb`, `.../cp5cde/cp5c/mkcases_inc.rb` | `tests/freestanding/e077/`, `tests/freestanding/e081/` |
| `tools/mlir/native/ab/test_e162_profile_reader.rb`, `docs/experiments/results/E162/cp1/{c01_scalar.rb,r29_*,r30_*}` | `tests/freestanding/profiles/` |

Notable local changes:

- `lib/Freestanding/Emit.cpp` marks every defined function `nounwind` in the
  LLVM IR. Under LLVM 23.1.1 the attribute set on each `func.func` does not
  survive translation, so an ARM object referenced `__aeabi_unwind_cpp_pr0` and
  the undef gate refused it; spinel-llvm ran on LLVM 22.1.8, where the optimiser
  inferred the attribute.
- `spinel-fs-emit` and `spinel-fs-grad` run `spinel-fs-codegen` where
  spinel-llvm ran clang: `clang -c` for the object, and a clang probe for the
  data layout (`spinel-fs-codegen --print-data-layout`). Both still stop at
  LLVM IR, keep the order of their steps, compare the layout again after the
  object is written and run the undef gate in-process; neither links a
  backend. `spinel-fs-codegen` (`lib/Freestanding/Codegen.cpp`) maps the
  profile's cflags, in one table, to a TargetMachine's CPU, feature list,
  float ABI, ABI name and optimisation level, beside clang's per-triple
  defaults, optimises with the PassBuilder's default pipeline and writes the
  object with the TargetMachine. A flag the table does not list is refused.
  The feature lists are clang 23.1.1's for every profile. `-ffreestanding
  -fno-builtin` now make every library function unavailable to the optimiser;
  for an IR input clang applied neither, and turned a zero loop into
  `__aeabi_memclr`. `-fshort-enums` changes nothing for an IR input, under
  clang as here. Neither did `-Os` under clang: optimising for size is the
  optsize attribute, which only C sources got, so the profiles' `-Os` compiled
  as `-O2`. `spinel-fs-codegen` marks every function the module defines optsize
  when the last `-O` is `-Os`, leaving one already optnone or minsize as it
  is, so the `-Os` profiles now optimise for size; `-Oz` stays refused. Both
  tools drop `--clang` and take `--codegen`, and `spinel-fs-grad` reads the
  object's symbols in-process rather than with `llvm-nm`. On Debian, the
  objects `tests/freestanding/run.sh` writes for the `-O2` profiles are
  byte-identical to the clang path's; those for the `-Os` profiles are mostly
  smaller (e084's Cortex-M33 kernel `.text` from 6374 bytes to 3146), and the
  results, the legs' agreement and the undef tables are the same.
- The runners take their tools from `tests/freestanding/lane-env.sh`, which has
  no home-directory or Homebrew defaults, write under `$FS_WORK` instead of beside
  the scripts, call `spinel-fs-emit` where spinel-llvm called its
  `spinel-mlirgen` front (same argv), and generate `cases.inc` with the Ruby
  generators spinel-llvm wrote to replace `mkcases.py`.
- Oracles are not on the runnable path: the host builds, the value joins
  (`compare.py`, `e063_gates.rb`), `run_nonreg.sh` and the byte comparisons with
  recorded tables. The original runners are kept under each lane's `oracle/`;
  the Python helpers were not imported. Their default `SCRATCH` directories
  and the paths in the recorded tables name the predecessor's two agent
  scratch directories as `/tmp/spinel-llvm-scratch/session-a` and
  `session-b` (path text only, 2026-10-30).
- Not ported: E083's target runs (they need the Enzyme-based differentiation
  tool), E040's undef rows e05-e07 (spinel-llvm's hosted MLIR importer), E077's
  control e11 (the retired `--types-from emit-types`). The runners name each as
  `NOT-PORTED`.
- Nine refusal patterns are updated to the native emitter's wording; two of
  them record diagnostic defects (E081 k6, E083 r7).
- `tests/freestanding/bm040` is written here, not imported (2026-10-19). It
  runs E040's kernel, unchanged, on QEMU's `mps2-an521` Cortex-M33 with no
  RTOS: its own startup code, linker script, UART console and Thumb-2
  setjmp/longjmp, linked `-nostdlib` with `kern.o` and compiler-rt's builtins
  built from the LLVM 23.1.1 sources (decision 0017,
  `docs/toolchains/compiler-rt-23.1.1`). Its profile,
  `cortex-m33-baremetal.yaml`, is `cortex-m33-zephyr.yaml` with
  `platform.type: none`. `lane-env.sh` gains `need_baremetal`
  (`BAREMETAL_BUILTINS`, `QEMU_ARM`), and `summary.rb` counts its `image` and
  `platforms` tables.
- `tests/freestanding/e040/run_frdm.sh` is written here, not imported
  (2026-10-19). It links E040's `cortex-m33-zephyr` `kern.o`, the object the
  QEMU run uses, with the unchanged `e040/zephyr` driver for Zephyr's
  `frdm_mcxn947/mcxn947/cpu0`, writes the image to an NXP FRDM-MCXN947 board
  through LinkServer on a Linux host over `ssh`, and compares the board's
  console with the QEMU run's. Nothing is taken from NXP beyond invoking
  LinkServer and Zephyr's own board definition. The lane is NOT RUN (exit 3)
  without that host, and `run.sh` reports it so unless `REQUIRE_ALL=1`. First
  run: LinkServer 26.3.123 for Linux aarch64, MCU-Link CMSIS-DAP firmware
  3.172, Zephyr 4.4.2 with SDK 1.0.1, LLVM 23.1.1 on macOS arm64; 31 cases,
  the panic trap and both consoles equal to QEMU's.
- `tests/freestanding/bm040-frdm` is written here, not imported (2026-10-19).
  It runs bm040 on the same board's secure CPU0 with no RTOS and no vendor
  SDK: bm040's profile, driver half, setjmp/longjmp and compiler-rt builtins,
  with its own startup code, linker script and LP_FLEXCOMM4 LPUART console.
  Nothing NXP or Zephyr wrote is compiled into it; the memory map, pins,
  clocks and register addresses are taken, with the file named in each
  comment, from Zephyr's DTS and board files, NXP's device headers in
  Zephyr's `hal_nxp` module, and the board user manual (UM12018). The host
  side of both board lanes moves into `tests/freestanding/frdm-host.sh`, and
  `run.sh`'s lanes treat exit 3 as NOT RUN. First run on the setup above:
  31 cases, the seven trap codes, the panic core halted on the trap hook's
  self-branch, no foreign symbol but four builtins members, and every row
  equal to bm040's QEMU run.

What runs where, and how, is in
[tests/freestanding/README.md](../tests/freestanding/README.md).

## WASM and edge capability (2026-09-23)

- Source repository: spinel-llvm (a private predecessor repository), revision `463d49dd`
  (read-only; not modified).
- Adoption date: 2026-09-23, as one batch on top of the freestanding target
  import above.
- License: as for the native core slice -- the source repository states none.
- Notices: none beyond the source's. The generated Workers and Fastly projects
  are the program's own; wrangler, workerd, Viceroy and the Fastly CLI are
  used as external tools and are not redistributed.

| Original | Local |
|---|---|
| `tools/wasm/**` except `README.md` and `legacy/README.md` | `tools/wasm/` |
| `tools/platform/**` except `README.md` | `tools/platform/` |
| `docs/experiments/results/E090/{reject,subjects}/**`, `E091/subjects/**`, `E093/{reject,subjects}/**` (the files `tools/platform/ab/e168_cases.tsv` names, and `k3_lib.rb`) | `tools/platform/ab/fixtures/E09{0,1,3}/` |
| `examples/{hello-http,fetch-kv,r2-d1,hello-fastly,gatekeeper,edge-twin}/**` except their READMEs | `examples/` |
| `examples/tools/{forge,kern_sig,post_fmt}.rb` | `examples/tools/` |

Notable local changes:

- **No vendor patch.** The default build rests on none. `--elim-bigint` needs
  Patch 5 and was already refused without it. `--request-arena` and
  `# spinel-tier: arena` need Patch 6 and are now refused too; before, a
  runtime without it ignored the define and built an ordinary collected module.
  Patch 4 (`SP_INT64`) is not in the pinned vendor either, so **Integer is
  32-bit on wasm32** here, where spinel-llvm had 64.
- **The pinned runtime is newer than spinel-llvm's vendor tree (`ecbd0f2a`)**,
  and four things broke. All four are fixed on the driver side:
  `shim_sigaction.h` (for `sigaction`), seven symbols in `stubs.c` (among them
  `madvise`, which must zero on `MADV_DONTNEED`), `shim_flockfile.h` (without
  it, wasm-ld put a trapping stub in place of `flockfile`), and three WASI
  imports in `wasi_shim.mjs`.
- No Homebrew or home-directory defaults; wasm-ld reports every undefined
  symbol; gatekeeper and edge-twin call `spinel-fs-emit`; and edge-twin's
  device half fails instead of exiting 0 when Zephyr is absent.
- The E168 case table now points at the local fixtures. Its golden comparison
  (`run_e168.sh`, `test_e168.rb`) is an oracle; it is kept and not run, and the
  goldens were not imported.
- The READMEs were written in Japanese. English ones replace them: for
  `tools/wasm`, `tools/platform`, both scaffolds and four examples.
- `tests/edge/` is new. spinel-llvm had build scripts and a demo for these
  examples but no checks. Each check comes from the example's own documented
  contract.

## Tensor lane: tensor_def, fusion and tensor_extern through IREE (2026-09-23)

- Source repository: spinel-llvm (a private predecessor repository), revision `463d49dd`
  (read-only; not modified). Adopted 2026-09-23 as one batch, on top of the
  WASM and edge import above.
- License: as for the native core slice -- the source repository states none.
- Third party: IREE 3.11.0 (Apache-2.0 with LLVM exceptions), installed
  user-local and not redistributed; see
  [its installation record](toolchains/iree-3.11.0/INSTALLATION-RECORD.md). The
  MNIST test set is downloaded at run time and checked by sha256; it is not in
  the repository.

| Original | Local |
|---|---|
| `tools/mlir/native/lib/Tensor/**`, `tools/mlir/native/tools/spinel-tensor-import/**` | the same paths |
| `tools/tensor/{sp_tensor_shim.c,spinel/tensor.rb}` | `tools/tensor/` |
| `examples/tensor/**`, `examples/image/**` except their READMEs | `examples/` |

Notable local changes:

- **No vendor patch.** The tensor lane needs none; spinel-llvm's vendor patch
  list has no tensor patch, and the pinned `spinel` already has `--link`.
- **`tools/tensor/spinel-tensor` is new**, and it restores what spinel-llvm had
  lost. At `463d49dd` the examples called `spinel-mlirgen --tensor ...
  --iree-compile ... --vmfb`; the native importer refuses `--vmfb` and
  `--iree-compile`, and the Python generator that handled them was retired
  (E176), so the examples no longer built there. The front runs the native
  importer and then the retired generator's own two `iree-compile` commands
  (llvm-cpu, and metal-spirv with `--iree-metal-compile-to-metallib=false`),
  compiling each backend from its device profile's module when the importer
  split the program by device.
- **The oracles are behind `SPINEL_ORACLE=1`.** Each example program computed a
  second implementation of its kernels (an f64 reference in plain Ruby, or
  `ref.c`) and printed the comparison on every run. That is an oracle, so it now
  runs only when asked; the default run prints only what the device run
  established. The code is otherwise unchanged.
- **Not imported:** the JAX training and export scripts
  (`docs/experiments/results/E034/train_export.py`,
  `E037/cnn_train_export.py`, `E037/export_variants.py`), because this
  repository admits no Python; and E037's CNN, whose checked-in modules have
  their weights elided (`*.elided.mlir`), so a runnable CNN needs a JAX export.
  The MLP (`examples/tensor/mnist`) carries its full weights and runs.
- `lib/Tensor` and `spinel-tensor-import` are unchanged; they bring six
  unused-variable and unused-function warnings with them.
- The READMEs were written in Japanese. English ones replace them for
  `tools/tensor`, `examples/tensor` and `examples/image`, and the per-example
  ones are folded into those two.
- `tests/tensor/run.sh` is new: spinel-llvm had build and run scripts but no
  checks. It checks what each example's own README says the run shows.

## Debian fixes to the three port batches (2026-09-23)

The freestanding, WASM/edge and tensor batches above, run on Debian 13
(x86_64) after the Mac. Local changes, all in the ported files, none in
`vendor/`:

- `tools/wasm/spinel-wasm`: two pipelines whose reader exits early (`head -1`,
  `grep -q`) ended the script with SIGPIPE (141) under `pipefail`, silently,
  about one run in two on Linux; the readers now consume their input.
- `tests/edge/run.sh`: re-executes itself under bash when started as `sh`,
  which is dash on Debian and cannot parse the file.
- `examples/{gatekeeper,r2-d1,edge-twin}/build.sh`: `stat -f%z` (BSD) became
  `wc -c <`.
- `examples/image/env.sh` and `examples/image/{filter,resize}/run.sh`: the
  Metal driver, frameworks and device only on Darwin, as the tensor examples
  already did.
- `tests/tensor/run.sh`: off Darwin, every example runs on the CPU and each
  Metal check is printed as not applicable, named and counted apart.

Host tools are recorded in the lanes' own documents: the freestanding
README, `tools/wasm/README.md`, and the IREE installation record.

## Host analysis tools: the allocation-freedom prover and the boxing census (2026-09-23)

- Source repository: spinel-llvm (a private predecessor repository), revision
  `463d49dd` (read-only; not modified).
- Adoption date: 2026-09-23. Imported as one batch, under the migration rules
  on `main` at `d39b5bf`.
- License: as for the native core slice above.
- Notices: none beyond the source's.

| Original | Local |
|---|---|
| `tools/realtime/{README.md,spinel-rtcheck,test/{cases.rb,expected.tsv,run.sh},ab/{run_e169.sh,test_e169.rb}}` | same paths |
| `tools/mlir/native/lib/Realtime/{CMakeLists.txt,MayAllocate.cpp,WholeModule.cpp}` | same paths |
| `tools/mlir/native/tools/spinel-rtcheck/{CMakeLists.txt,main.cpp}` | same paths |
| `tools/llvm/build_rt_bc.sh` | same path |
| `tools/census/{README.md,spinel-boxing-census,spinel-codegen-audit,emit_c_hashes.sh,run_census_gate.sh,baseline/{doom.tsv,vendor_bd2d276a.tsv}}` | same paths |

`tools/realtime/alloc_vocabulary.tsv`, `cmake/GenAllocVocabulary.cmake` and
`include/spinel-mlir/Realtime/` came with the freestanding batch and are
unchanged.

Local changes:

- `lib/Realtime/CMakeLists.txt` names the LLVM components it uses (Core,
  IRReader, BitReader, Linker, Object); the source linked one LLVM dylib, and
  the LLVM here is static components.
- `lib/CMakeLists.txt`, `tools/CMakeLists.txt` and `build.sh`'s target list
  gain `Realtime` and `spinel-rtcheck`.
- `spinel-rtcheck/main.cpp`: an entry spelled as a top-level method resolves
  to `sp_<name>`, and to `sp_rb_<name>` when only that exists; the pinned
  Spinel emits the second for names that could collide with a runtime symbol.
- `tools/llvm/build_rt_bc.sh` is the only file of spinel-llvm's LLVM backend
  taken: it builds the runtime bitcode the prover links.
- The Japanese READMEs of `tools/realtime` and `tools/census` are replaced by
  English ones.

Kept as files and not run, being oracles: `tools/realtime/ab/` (a byte
comparison with the frozen Python prover) and `run_census_gate.sh` with
`baseline/` (counts recorded at spinel-llvm's Spinel pin `bd2d276a` and over
its `doom/` sources, which are not here).

Imported but not runnable at this pin, because they read the output of
spinel-llvm's vendor patches: `spinel-codegen-audit` and `spinel-boxing-census
where` (L2 `SPINEL_LLVM_TYPES_NODE_ID`; L3/L4 `SPINEL_LLVM_CODEGEN_FACTS`).
`emit_c_hashes.sh` checks such a patch and has none to check here.

Not imported: `tools/gcmon` (E131). Its probe and both of its tests use the
fork's `SPINEL_EXTERN_METHODS` hooks (Patch 1), its pause measurement needs
patch L8 (`--pause`, the GC trace), and its gate runs spinel-llvm's `doom/`
and R007's macOS-only allocation counter. None of these is in the pin.

## Differentiable Ruby: grad_def and the gradient lanes (2026-09-23)

- Source repository: spinel-llvm (a private predecessor repository), revision
  `463d49dd` (read-only; not modified).
- Adoption date: 2026-09-23. Imported as one batch, under the migration rules
  on `main` at `d39b5bf`.
- License: as for the native core slice above.
- Third-party dependency: Enzyme v0.0.290 (Apache-2.0 with LLVM exceptions),
  built user-local and not vendored; see
  [its installation record](toolchains/enzyme-0.0.290/INSTALLATION-RECORD.md).
  No Enzyme source is in this repository.

| Original | Local |
|---|---|
| `tools/grad/**` (`spinel-gradgen`, `spinel-searchgate`, `rules/`, `spinel/`, `ab/`) | `tools/grad/` |
| `tools/llvm/passes/{CMakeLists.txt,SpinelGCRoots.cpp,README.md,test/**}` | `tools/llvm/passes/` |
| `tools/mlir/native/tools/spinel-fs-grad/{CMakeLists.txt,main.cpp}` | same paths |
| `docs/experiments/results/E076/**` | `tests/grad/e076/` (tables in `oracle/`) |
| `docs/experiments/results/E082/**`, `.../E080/tables/margin_curve_eps{255,8}.tsv` | `tests/grad/e082/` (tables and oracles in `oracle/`) |
| `docs/experiments/results/E079/**` | `tests/freestanding/e079/` |
| `docs/experiments/results/E083/**` (beyond the reject table already here) | `tests/freestanding/e083/` |
| `docs/experiments/results/E084/**` | `tests/freestanding/e084/` |

`lib/Freestanding/Grad{Declaration,Pipeline,Shim}.cpp` and their headers came
with the freestanding batch and are unchanged, except for one comment in
`GradShim.cpp` that named the `clang -c` the object no longer goes through.

Local changes:

- `spinel-fs-grad` links the LLVM components its pipeline uses (Passes, ipo,
  Linker, Plugins) and exports its symbols to plugins, as `opt` does. spinel-llvm
  linked one LLVM dylib, which supplied the symbols the Enzyme plugin resolves
  from its host. Its default plugin name is `LLVMEnzyme-23`.
- `spinel-gradgen` takes the LLVM from `LLVM_PREFIX` and the plugin from
  `ENZYME`. Off macOS, it links `-lcrypt` into its gate driver. It spells the
  pinned runtime's float `sp_float` (spinel-llvm: `mrb_float`), and spells the
  rules prototypes' `int64` as `int64_t`, as the pinned compiler declares the
  same function. `rules/spinel_grad_rules_enzyme.c` spells it the same way.
  When `spinel-rtcheck` stops without writing a verdict, G2's O5 refusal
  carries rtcheck's last stderr line (or its exit status); spinel-llvm reported
  the verdict as `?` alone.
- `tools/llvm/passes/test/run.sh` takes FileCheck from `FILECHECK`, because the
  LLVM release ships none. `nogc_list.py` was not imported.
- The lanes call `spinel-fs-grad` where spinel-llvm's runners still called the
  retired `spinel-gradfs`. They write under `$FS_WORK` or `$GRAD_WORK`, and they
  run their host leg on this machine: x86-64 Linux gets `x86_64-host*.yaml`
  profiles beside the arm64 ones.
- Checks that spinel-llvm computed in inline Python are in Ruby: E082's Newton
  gate, E084's Hessian symmetry and its host Newton gate. E083's wasm import
  list is read with node, because the LLVM release ships no `obj2yaml`.
- E083's and E084's extern-check rows are `NOT-PORTED`. They checked a C shim
  that only the retired `spinel-gradfs` wrote.
- The Japanese READMEs of `tools/grad` and `tools/llvm/passes` are replaced by
  English ones.

Kept as files and not run, being oracles:

- `tools/grad/ab/`, with its E171 goldens, which were not imported;
- `tools/llvm/passes/test/run_rb.sh`, which compares against the stock build;
- E079's `model.py` (Python, not imported);
- E082's `rules_check.c`, `analytic_check.c` and `nonreg`;
- E083's trajectory compared with E079's stored results;
- E084's `analytic_check.c`, `host_mirror.c` and `unfuse_fmuladd.py` (not
  imported);
- demoA's f64 Ruby comparison, behind `SPINEL_ORACLE=1`;
- every recorded table, under the lanes' `oracle/` directories.

## DOOM GPU raster: the Job IR lane attached to this tree's DOOM (2026-09-23)

- Source repository: spinel-llvm (a private predecessor repository), revision `463d49dd`
  (read-only; not modified). Adopted 2026-09-23 as one batch, on top of the
  tensor lane above. License: as for the native core slice.

| Original | Local |
|---|---|
| `tools/raster/**` except `README.md` | `tools/raster/` |
| `doom/bin/{dump_jobs,gpu_demo,gpu_reject}.rb` | `examples/doom/bin/` (manifest rows added; identical at `f8ad13c6` and `463d49dd`) |

Notable local changes:

- **Attached to this repository's DOOM, not spinel-llvm's copy.** The two
  reconcile without change: all 35 library files and the demo drivers are
  byte-identical to spinel-llvm's at `463d49dd`, and `bin/doom.rb` differs only
  by decision 0008's `-core` route; its `-gpu` path is intact.
  `examples/doom/build.sh` gains `RASTER_GPU=1`, which links `tools/raster`'s
  seam, the IREE runtime and Metal in place of `native/sp_rg_stub.c`. Unset,
  the build is unchanged.
- **No vendor patch.** Metal kernels are compiled with
  `--iree-metal-compile-to-metallib=false`: this machine has no Metal
  toolchain, and installing one would change a shared Xcode component.
- **Oracles kept as files:** `gpu_demo.rb` (GPU against CPU executor frames),
  `raster_run.c`'s comparison, and `ab/` (byte comparison with the retired
  Python). E073 and E075's recorded tables are not imported.
- **High resolution needed one DOOM fix.** At scale 3 and above, DEMO1 stopped
  at tic 321 on this tree, on the plain CPU renderer as well: `render_seg_loop`
  read `finetangent` one past its end when the view angle sum was exactly
  ANG180. The read now returns `finesine[0]`, as vanilla gets from the next
  table in memory; the same guard is in the CORE extraction. `render.rb` is
  marked `modified=yes` in the manifest, and `examples/doom/NOTICE.md` records
  it. E075's Python analysis scripts are not imported.
- `tests/raster/run.sh` is new. It checks the lane's own tools and refusals, and
  that every demo plays to its end with every frame from the GPU.

## spinel-ebpf: the eBPF-accelerated Ruby HTTP server and probe DSL (2026-09-23)

- Source repository: spinel-ebpf (a local checkout; private), revision
  `23fa4b062fc425ebd4132cbe705621a14b2c130d` (2026-08-26), read-only; not
  modified. One example file comes from the public `yuskesh/spinel-ebpf` at
  `58e6ca3` (`examples/http_server/so-reuseport/server.rb`).
- Adoption date: 2026-09-23. Imported as one unit, under the migration rules
  on `main`, after the owner approved Patch 1 and administrator rights for eBPF.
- Vendor: it needs Patch 1 (`SPINEL_EXTERN_METHODS`, above) and nothing more.
  Its in-process codegen reads the pinned compiler's internal structs through
  `src/codegen_c/spinel_upstream_contract.h`; every field it names exists at
  `573aa44c`.
- Third-party sources, not vendored: nanopb 0.4.9.1 and mbedTLS 3.6.6, named by
  `NANOPB_DIR` and `MBEDTLS_DIR`
  ([installation record](toolchains/spinel-ebpf-deps/INSTALLATION-RECORD.md)).
  The generated OTLP protobuf sources under `src/runtime/otlp/pb` are imported
  as spinel-ebpf committed them (generated from opentelemetry-proto).
- License: as for the other predecessor imports above; nanopb (zlib) and
  mbedTLS (Apache-2.0) keep their own notices in their checkouts.

| Original | Local |
|---|---|
| `bin/`, `src/`, `include/`, `tools/`, `scripts/`, `profiles/`, `tests/`, `examples/`, `benchmarks/`, `plugin.toml` | `tools/ebpf/` (same layout) |
| (new) | `tests/ebpf/run.sh`, `tests/ebpf/live.sh` |

Not imported: `docs/` (3,327 files of experiment records, ADRs and logs),
`articles/`, `presentation/`, `repos/`, the `third_party/` submodules, and the
four Python files.

Local changes, listed in `tools/ebpf/README.md`: the compiler is
`vendor/spinel`, and the in-process link adds its regexp objects; nanopb and
mbedTLS come from the environment; the defaults naming a sibling `spinel-llvm`
checkout are removed; two tests read files in this tree; lab host addresses and names
in a recorded result, a README and two usage comments are documentation
ones (RFC 5737 and RFC 2606, 2026-10-30).

Kept as files and not run, being oracles or benchmarks: `benchmarks/` (nginx),
the golden, baseline and form gates, the OTLP harnesses that decode with protoc
or a Python mock (the owner ruled them not oracles on 2026-10-24, below), and
the MLIR shadow against spinel-llvm. Not runnable on this
host: the GPU lane (macOS), the AMP firmware lane, and what needs spinel-llvm.

**OTLP mock receivers, written here (2026-10-24).** Not a port: the three
Python mock servers were not imported, and `tools/ebpf/tests/runtime/`
`mock_otlp_receiver.rb`, `mock_otlp_grpc.rb` (with `mock_hpack.rb`, HTTP/2
and HPACK written here) and `mock_tls_server.rb` (with `mock_support.rb`)
are new Ruby for CRuby, written to the predecessor mocks' observable
behaviour at `23fa4b0` (their command lines, captures and replies). The owner
chose this over a new gem or a vendor change (2026-10-24); no gem is added,
and TLS is CRuby's bundled openssl. The twelve harnesses that start a mock
run them under `setsid` and stop the process group, the inline Python in
them is Ruby, `grpc_guard.sh` (which looked for a Python with grpcio) is
removed, `run_otlp_tls.sh` and `run_otlp_tls_smoke.sh` take mbedTLS from
`MBEDTLS_DIR` as `scripts/build-mbedtls.sh` already did, protoc reads
opentelemetry-proto from `OTEL_PROTO_DIR`, and `run_otlp_kernel_e2e.sh` and
`run_gpu_host_probe.sh` can give their probe capabilities in `EBPF_CAP_DIR`
([README](../tools/ebpf/README.md#the-otlp-harnesses-and-their-mock-receivers)).
protoc 31.1 and opentelemetry-proto `ca839c51` (v1.10.0, spinel-ebpf's
submodule commit) are user-local
([installation record](toolchains/spinel-ebpf-deps/INSTALLATION-RECORD.md)).
Run once on Debian 13 x86_64, kernel 7.1.8, 2026-10-24, under the owner's
approval of this batch (`run_otlp_kernel_e2e.sh` with `ALLOW_ORACLE=1`; the
other eleven have no gate): eleven pass, and `run_gpu_host_probe.sh` is not
run to its end, its uprobe refused with the three capabilities granted (the
installation record). The gRPC mock was also checked with curl 8.14.1
(nghttp2 1.64.0) as the client: h2c and grpcs calls answered `grpc-status: 0`
with the message decoded, ALPN `h2` selected, an HTTP/1.1-only TLS client
refused, an unknown method answered 12. Its HPACK tables equal Go's
`x/net/http2/hpack`, and it decodes RFC 7541's C.4 examples.
On 2026-10-24 the owner ruled the sixteen harnesses that decode with protoc
not oracles, `run_otlp_kernel_e2e.sh` excepted
([decision 0020](decisions/0020-oracle-gate.md)), and approved one run of
`run_gpu_host_probe.sh` with `cap_sys_admin` added: it passed (3 series of
50, the negative control refused). The owner then approved granting
`cap_sys_admin` in that harness's `EBPF_CAP_DIR` path, and the harness, so
changed, passed its one run.
Then `run_otlp_json.sh` checks its JSON with CRuby's parser instead of
python3's, and nine more harnesses read opentelemetry-proto from
`OTEL_PROTO_DIR` (`run_otlp_roundtrip`, `_metrics`, `_logs`, `_traces`,
`_trace_asm`, `_k8s`, `run_amp_ring`, `_trace` and `_s3`). Each ran once on
Debian 13: nine pass. `run_amp_s3.sh` does not run here: its AOT driver
depends on `tools/rbpf-for-microcontrollers`, which was not imported, so the
cargo build fails, and its fallback manifest is under spinel-ebpf's
`docs/experiments`, which was not imported either.

Checks, Debian 13 x86_64, host kernel 7.1.8:
- `tests/ebpf/run.sh`: minitest 50 files, 1459 runs, 0 failures, 0 errors,
  0 skips; runtime harnesses 7 of 7. 106 s.
- `tests/ebpf/live.sh`: 12 of 12. It checks the M002 server's answers and its
  L7 counter (1=2, 2=1, 3=1); the M003 workers (40 of 40, 4 listeners), the
  sk_reuseport program loaded, and its SOCKARRAY holding 4 sockets; M004's XDP
  responses with no listener (`/health` OK, `/hello` hello), each detached
  after; and XDP early reject (ping 100% lost, TCP 200, 3 of 3 counted, ping
  back after). 18 s.

**English documentation (D1, 2026-10-31).** The 19 Markdown documents under
`tools/ebpf/` that were in Japanese (the benchmark README, METHODOLOGY_AUDIT.md
and result summaries, the tools README, the profiles README and the example
READMEs) are translated to English here, one commit each on
`docs/d1-english`. Measured figures, commands, paths and Edoc numbers are kept;
links into the unimported `docs/` tree are kept as they were, except the two
P001 links into Japanese anchors, which keep their text and lose the link. Code
comments keep their original language.

**English messages (D2, 2026-10-31).** The user-facing strings of
`tools/ebpf/` outside `go/` (CLI help and errors, the capabilities catalog,
the introspect, portability, MLIR shadow, schema and object reports, and the
tools, examples, scripts and runtime messages; 1,292 lines in 37 files) are
translated to English here, on `docs/d2-english-messages`, commits ffc5aba,
d8008a8, bcdd7f5, 5c0bc79, 1478b78, 1ed4347 and ba7d241. Keys, symbols,
identifiers and the text written into generated code are unchanged; tests that
match a message follow it in the same commit. `introspect.rb`'s annotation
pattern keeps its full-width colon: it reads annotations that users write.
A later import from spinel-ebpf reapplies these commits as a patch series, or
redoes them, before it lands.

- **Metal compute, renamed 2026-11-09.** The GPU kernels and their harnesses moved
  from `tools/ebpf/examples/gpu` and `tools/ebpf/tests/runtime/` to `tools/metal/`,
  and the command for them is now `spinel-metal`. The generator is still the
  `gpu-metal` target of `tools/ebpf`, which `spinel-metal` calls.

## GC monitoring: the section probe, the driver and DOOM's allocation gate (2026-09-23)

- Source repository: spinel-llvm (a private predecessor repository), revision `463d49dd`
  (read-only; not modified), its E131. Adopted 2026-09-23 as one batch, on the
  Patch 1 pin above. License: as for the native core slice.

| Original | Local |
|---|---|
| `tools/gcmon/{gcmon_contract.h,gcmon_probe.c,gcmon_stub.rb,spinel-gcmon,run_gcmon_gate.sh}` | `tools/gcmon/` |
| `tools/gcmon/test/{probe_properties,probe_noninvasive}.rb` | `tests/gcmon/` |
| `docs/researches/r007_probes/malloc_count.c` (last changed at `8db05e0c`) | `tools/gcmon/malloc_count.c` |
| `doom/bin/bench_tic.rb` | `examples/doom/bin/` (manifest row added; identical at `f8ad13c6` and `463d49dd`) |

Notable local changes:

- **Comments and messages are in English**; the README is rewritten.
  `malloc_count.c` and `bench_tic.rb` change nothing but, for the first, its
  header comment; `bench_tic.rb` is byte-identical, as the DOOM manifest
  requires.
- **The probe's integer type follows the pin.** spinel-llvm's contract used
  `int64_t` for `mrb_int`; Patch 1 at `573aa44c` declares `sp_int`, which is
  `intptr_t` (`lib/sp_types.h:90`), so `gcmon_int` is `intptr_t`. The counter
  line references are re-read at the pin.
- **NOT PORTED: the pause-time axis.** spinel-gcmon's `--pause` read
  `SPINEL_GC_TRACE` from vendor patch L8, which is not approved. `--pause` is
  refused with exit 2 and a message naming L8; the `gc_trace` rows are gone.
- **Two holes closed in `ab --expect-zero`.** An attached instrument that says
  nothing on a side is now a `(no output)` MISSING row: before, a non-Spinel
  subject wrote no GC report on either side, left no key at all, and passed.
  And a subject that exits non-zero now fails the verdict instead of only
  warning.
- **The gate builds its subject from this tree** (`spinel --cc="$CC"`, rebuilt
  every run), reads the IWAD from `build/doom-wad` or `WAD`, SKIPs on a host
  without DYLD interposition, and turns any spinel-gcmon error into FAIL.
- **Not run: `gcmon_stub.rb`'s CRuby differential**, which is an oracle; the
  file is kept.
- `tests/gcmon/run.sh` is new: the two ported tests, the driver's verdicts with
  a positive control (300 extra allocations fail), the `--pause` refusal, and
  the gate.

## Shader lane: Ruby shaders to SPIR-V, WGSL and MSL (2026-09-23)

- Source repository: spinel-llvm (a private predecessor repository), revision `463d49dd`
  (read-only; not modified), its P006 (E133–E145). Adopted 2026-09-23 as one
  batch, on the GC monitoring port above. License: as for the native core
  slice.

| Original | Local |
|---|---|
| `tools/shader/**` except `test/heavy.rb` and `golden/flat.linux-x86_64-nvidia-geforce-rtx-4090.tsv` | `tools/shader/` |

Notable local changes:

- **`spinel-rb2spv` has no Homebrew or apt default for LLVM.** It takes
  `LLVM_BIN`, else `$LLVM_PREFIX/bin`, else stops. The MLIR tools are the LLVM
  23.1.1 release's; spinel-llvm used Homebrew's LLVM 22. This is the only
  source change; the imported comments are kept in their original language,
  and the README is new, in English.
- **Textures were added here (decision 0029, 2026-11-09), not imported.**
  `spinel-rb2spv`, the comparison tools' entry refusal, `draw.c`'s texture input
  and its 16-attribute limit are local, as are `tools/shader/test/tex*.rb`, the
  new refusal cases and `tests/shader/tex_scene.rb`.
- **`test/heavy.rb` is not imported.** It was E134's timing subject (900
  operations a channel), and the generator's later depth ceiling (E135, 126)
  refuses it (`ChainTooDeep`, depth 904), so it no longer compiles.
- **The Linux per-device golden is not imported.** It records one host's GPU
  model, driver and kernel versions (a machine inventory, which AGENTS.md
  keeps out), and it serves only the gate's oracle comparisons.
- **Oracles kept as files, not run:** `spinel-shader-cmp`,
  `spinel-shader-vcmp`, `spinel-shader-attrib` (it matches GPU output against
  CPU builds of each fusion candidate), the CPU references the generator
  writes, `golden/`, and `run_shader_gate.sh`. The gate also expects
  spinel-llvm's untracked wgpu-native and Dawn under
  `docs/researches/r010_probes/vendor`, which are not imported.
- **Tools installed user-local:** wgpu-native v29.0.1.1 only; naga-cli 29.0.0
  and SPIRV-Tools were already present. Dawn is not installed; it served only
  the wgpu/Dawn comparison.
  [Installation record](toolchains/shader-tools/INSTALLATION-RECORD.md).
- **No vendor patch.** The generator reads `spinel --dump-ast` and
  `tools/contract`'s `spinel-typedump`, both of which work at this pin
  unchanged.
- `tests/shader/run.sh` and `check_image.rb` are new. They check the lane's own
  contract: `spirv-val` acceptance, naga conversion, the emission check,
  SPIR-V invariance under the MSL lane, the refusals, Metal compiling and
  drawing the MSL (with a broken-MSL control), and wgpu-native drawing the
  WGSL, including the vertex pipeline's coverage against its scene's vertices.

## LLVM backend driver, spinel-vi and mvc-blog (2026-09-23)

- Source repository: spinel-llvm (a private predecessor repository), revision `463d49dd`
  (read-only; not modified). Adopted 2026-09-23 as one batch, on the shader
  lane above. License: as for the native core slice, except the vendored C
  below.

| Original | Local |
|---|---|
| `tools/llvm/{spinel-llvm,cc-lto-shim}` | `tools/llvm/` (README new) |
| `examples/spinel-vi/**` | `examples/spinel-vi/` (vendored C trimmed, below) |
| `examples/mvc-blog/**` | `examples/mvc-blog/` |

`tools/llvm/build_rt_bc.sh` and `tools/llvm/passes/` came with the earlier
batches and were already identical to `463d49dd`.

Notable local changes:

- **The LLVM is `LLVM_PREFIX`'s**, the official 23.1.1 release, in
  `spinel-llvm`, `cc-lto-shim` and `build_rt_bc.sh`; `LLVM=` still overrides,
  and there is no Homebrew default.
- **`spinel-llvm`'s link line follows `src/main.c` at pin `573aa44c`**:
  `-Werror=incompatible-pointer-types -Werror=int-conversion -ferror-limit=0`,
  the `_mt` variant of a `--link` object for a threaded program, `native_obj`
  deduplication with the `_mt` marker removed, and `-lcrypt` off macOS. The
  runtime now has 29 sources in `lib/` (spinel-llvm's pin had 25); the bitcode
  builder globs them and still matches `RT_MEMBERS`.
- **spinel-vi's vendored C is trimmed** to the files its translation unit
  reaches, with their notices: termbox2 keeps `termbox2.h`, `LICENSE` and
  `README.md` (its demos, tests and a Python example are not imported);
  libgrapheme keeps three sources, three headers and the generated
  `gen/character.h` and `gen/types.h`, with `LICENSE` (ISC) and the Unicode
  License v3 that accompanied the data those tables are generated from
  (`data/LICENSE`); the 22 MB of Unicode data files are not imported.
  `vendor/libgrapheme/SNAPSHOT.md` records the trim.
- **Two spinel-vi fixes for the pinned compiler.** The C shim defined
  `int sp_ffi_bin_len`, which the pinned runtime now defines
  (`lib/sp_alloc.c`); ld64 merged the two with a duplicate-symbol warning. The
  shim now declares it. And a `:binstr` FFI return is now a binary String, so
  a loaded file inspected as `"\xE3\x81\x82"`; `FileStore.load` marks the text
  UTF-8 once the C side has validated it, and the recorded screen digests hold
  again.
- **spinel-vi's gates no longer call the experiment archive.**
  `test/run-e103-gates.sh` called spinel-llvm's `docs/experiments/results/E101`
  and `E102` gates; it now runs the example's own `run-editor-gates.sh` when
  its binary is missing, and `tests/spinel-vi/run.sh` carries the Spinel legs
  of E101 and E103–E106.
- **mvc-blog's `VALIDATION.md` is kept as a labelled historical record**,
  because the sources cite it. Two of its defects (§4-1, `str[i] == "x"`
  after a multibyte character; §4-3, the word `Set` stopping the wasm build) no
  longer reproduce at this pin. The READMEs of both examples are new, in
  English; the imported comments keep their original language.
- **English documentation (D1, 2026-10-31).** `examples/mvc-blog/VALIDATION.md`
  and `examples/spinel-vi/vendor/libgrapheme/SNAPSHOT.md` are translated to
  English here. VALIDATION.md keeps its ten measured data lines in Japanese,
  and English sentences beside them say what the Japanese input tests; they are
  records of what was measured and are not rewritten, including when D2 puts
  the blog's view strings into English.
- **Oracles not run:** spinel-vi's `test/core_oracle.rb`,
  `test/core_flat_oracle.rb` and the CRuby legs of its fixtures, and
  `tools/llvm/passes/test/run_rb.sh` (as recorded for the gradient batch).
  Benchmarks are not run.
- **The upstream suite through `cc-lto-shim` was not run to completion**: at
  about 3.4 tests a second, the 3,696 tests take about 20 minutes on the macOS
  arm64 build machine. Stopped after about 6 minutes, it had passed all 16
  auxiliary targets and 729 corpus tests, with no failure. The command:
  `make -C vendor/spinel test CC="$PWD/tools/llvm/cc-lto-shim" NO_CCACHE=1`.
- New checks: `tests/llvm/run.sh`, `tests/spinel-vi/run.sh` and
  `tests/mvc-blog/run.sh`.

## DOOM PPM writer and the examples index (2026-09-23)

- Source repository: spinel-llvm (a private predecessor repository), revisions `f8ad13c6` and
  `463d49dd`, identical for these files (read-only; not modified).

| Original | Local |
|---|---|
| `doom/bin/dump_ppm.rb` | `examples/doom/bin/dump_ppm.rb` (manifest row, unchanged) |
| `doom/lib/doom/ppm.rb` | `examples/doom/lib/doom/ppm.rb` (manifest row, unchanged) |

- `examples/doom/bin/frame_ppm.rb` is written here (`kind=local`): it writes one
  frame that `bin/sim_demo.rb` dumped as a PPM, through the same `Doom::Ppm`.
  `dump_ppm.rb` itself writes WAD pictures only.
- `examples/README.md` is new: an index of this tree's examples. spinel-llvm's
  index described its own tree and is not imported.
- `tests/doom/ppm.sh` checks that two WAD pictures and one rendered frame
  (DEMO1, tic 399) are valid PPM files of the right size.

## The SpBPF MLIR lane and the Go path to eBPF (2026-09-23)

- Source repository: spinel-llvm (a private predecessor repository), revision `463d49dd`
  (read-only; not modified), from the macOS implementer's gap audit of spinel-llvm.
- Adoption date: 2026-09-23, as one unit on `integration/stage3-ports-2`.
- Vendor: nothing beyond Patch 1.
- Third-party: Go 1.25.14 user-local
  ([record](toolchains/go-1.25.14/INSTALLATION-RECORD.md)); Go modules from the
  public proxy, checked against `go.sum`.

| Original | Local |
|---|---|
| `tools/mlir/native/{include/spinel-mlir/Dialect/SpBPF,include/spinel-mlir/Target/SpBPF,include/spinel-mlir-c,lib/Dialect/SpBPF,lib/Target,lib/CAPI}` | same paths |
| `tools/mlir/native/tools/{spbpf-compile,spbpf-opt,spinel-mlir-capi-smoke}` | same paths |
| `tools/mlir/native/unittests/Target/SpBPF` | same path (a plain executable, no gtest) |
| `tools/mlir/native/test/{Dialect,Target}/SpBPF` | same paths |
| `tools/ebpf/go/{cmd,internal,spbpf,testdata,go.mod}` | `tools/ebpf/go/` (beside the spinel-ebpf tree) |
| `examples/ebpf-go/{xdp-counter,otlp-agent}` | `examples/ebpf-go/` |

Local changes:

- The native build gains the lane as separate targets: `spbpf-compile`,
  `spbpf-opt`, `spinel-mlir-capi-smoke`, and, through a new `TEST_TARGETS`
  list that `build.sh` checks against `unittests/`, `spinel-spbpf-schema-test`.
  No existing target links it; the twelve existing binaries rebuilt
  byte-identical.
- The lit tests run under `tests/spbpf/run.sh`, which reads their RUN lines
  itself, because lit is Python. It uses FileCheck and `not` from `FILECHECK_DIR`
  and runs each line with pipefail. Three tests call spinel-llvm's
  `spinel-mlirgen` and are `NOT-PORTED`.
- `tools/ebpf/go/run_gate.sh` is replaced by `tests/ebpf-go/run.sh`, which
  drops its otlp-agent step and its `/usr/local/go` default. The kernel check
  is `tests/ebpf-go/live.sh`, which runs on `lo` with file capabilities
  instead of as root in a network namespace.
- The READMEs of both examples are replaced by English ones.
- The user-facing messages of `tools/ebpf/go/` (5c6c744) and of both examples'
  `main.go` (7e7a6ab) are in English (D2); `objects_gen.go`, which
  `generate.go` writes, is unchanged.

Dropped, not ported (the cross-repository gate existed so that spinel-ebpf
could consume spinel-llvm; both now live here): spinel-llvm's
`tools/ebpf/run_gate.sh` (95 KB), `gate_manifest.tsv`,
`run_core_verification.sh`, `test_core_verification.sh`,
`test_gate_capability.sh`, `test_gate_manifest.sh`,
`test_btf_layout_mutation.sh`, `test_wasm_tool_resolution.sh`, and the
`SPNL_LLVM_ROOT` plumbing they served. Its README is not imported.

Kept as files, not run: `examples/ebpf-go/otlp-agent`, which is the Go leg of
E156's three-way differential and so an oracle, and
`tools/ebpf/go/testdata/kernel/*.sh`, which run as root.

## spinel-bpf-mlir v0.7.0 and its loader bml: the bcc tools (2026-10-26)

Imported as one unit on `feat/bcc-import`, under the owner's decision of
2026-10-26 to take in spinel-bpf-mlir's 28 bcc tools. The plan and its
decisions are outside the repository (the implementer's `bcc-import-plan.md`).

- **Sources.**
  - spinel-bpf-mlir (the bpf-mlir project's; it has no public remote), the
    local annotated tag `v0.7.0`, commit
    `04eee01612d47042369b62d232afe73edfebe521`, then updated in place to
    main `4b936d5fe7e7ea50d1644e1952b4ac2599bd8fef` (E152: the driver takes spinel-mlir's
    consumer outputs through `--seam-emit` and `--seam-inspect`). The update
    is upstream's diff for eight files (`cmd/spinelbpf/{build,main,seam}.go`,
    `e152_test.go`, `testdata/verified.tsv`,
    `internal/frontend/{domainread,uprobecheck}.go`,
    `examples/bcc/PROVENANCE.md`), applied as it is; the local changes below
    did not need replanting, and bml's pin is unchanged.
  - **v0.8.0 (2026-10-27).** The tree was then updated to the local tag
    `v0.8.0`, commit `1ffc9791e0a564b6654fe81db16bcf65b48cba0d` (P029: the
    seven tools of the third wave, tcpconnect, tcpaccept, tcpretrans,
    biosnoop, gethostlatency, deadlock and sslsniff), on the owner's
    decision of 2026-10-27. The update is upstream's `4b936d5..v0.8.0` diff
    over the imported paths, 124 files without the generated outputs,
    applied as it is; the local changes below did not need replanting.
  - **bml `a6da571` (2026-10-27).** The commit v0.8.0 pins,
    `a6da571e43c5e4a1d1a5b9d997e5201773f49c35`. bml's `295df2a..a6da571`
    diff over the imported paths, 88 files, was applied as it is. Both
    sources now pin bpf-mlir go/v1.18.0 (`3bdd550e`); libbpf, zlib and
    elfutils are unchanged.
- **Main `9b914a8` and bml `fae2194` (2026-10-30, stage PU).** The tree was then
  updated to main `9b914a87fca5507fab7470bf636db96c91cd4f7d` of spinel-bpf-mlir, under the bpf-mlir coordinator's PU
  decisions of 2026-10-30. That revision has E160 (the development pin moves
  to `ab0db4b40`, an unreleased commit of bpf-mlir's development tree), E161 (the public build shape, pinned to
  bpf-mlir v1.20.0, `d3e13842`, with go-bpf-mlir v0.18.0), and E161's
  addendum (no old module path left in the public shape's tests or comments).
  - The update is upstream's `1ffc979..9b914a8` diff over the imported paths,
    applied as it is: 24 files, 11 of them new. Upstream's README, its `docs/`
    and the regenerated outputs under `examples/` are not imported.
  - bml's `a6da571..fae2194f48d1383a603f619cffb62cc64ede1d98` diff over the imported paths, 15 files, was
    applied as it is.
  - One local change was replanted: the development shape's seam fallback
    `cmd/spinelbpf/seam_pin_dev.go` reads `third_party/PINS` (below), not the
    gitlink.
  - `third_party/PINS` now records `ab0db4b40` for both sources, and
    `d3e13842` as a separate fact.
  - This repository builds and tests the development shape. The export
    produces the public shape (`tools/dist/manifest.json`).
  - Its C loader bpf-mlir-loader (bml), the commit spinel-bpf-mlir pins:
    `295df2ad877091826ac98a6778022fcf53b02eb1`. bml is a `file://`
    submodule there and cannot be cloned elsewhere, so it is imported as
    source.
  - Both were read only, through `git archive`, and were not modified.
- **Main `cf77cec` (2026-10-30, E161's addendum 2).** The tree was then
  updated to main `cf77cec1d94f62b6d44593bb85359a503d2944fd` of spinel-bpf-mlir. Its addendum 2 splits the
  tests' version expectation and build tag by shape (`form_dev_test.go`,
  `form_public_test.go`), moves `e098_test.go` to the development shape, and
  reads two bpf-mlir test inputs from copies under
  `cmd/spinelbpf/testdata/bpfmlir/` instead of `third_party/bpf-mlir`.
  - The update is upstream's `9b914a8..cf77cec` diff over the imported
    paths, applied as it is: 13 files, 7 of them new. Its `docs/` is not
    imported.
  - The four copied inputs are bpf-mlir's, under Apache-2.0 WITH
    LLVM-exception; the copy's `PROVENANCE` names their source paths and git
    blobs, and `docs/imports.tsv` gives them their own row.
  - The bpf-mlir gitlink is unchanged (`ab0db4b40`), so `third_party/PINS`
    keeps its values.
- **Main `8b20ffa` (2026-10-30, E161's addendum 3).** The tree was then
  updated to main `8b20ffa58b1e50fd0bc7c40cbd2db4cf30c3218c` of spinel-bpf-mlir, upstream's
  `cf77cec..8b20ffa` diff over the imported paths, applied as it is: 2 files.
  The copies' `PROVENANCE` names the public bpf-mlir v1.20.0 (`d3e13842`) as
  their source, with the development commit `ab0db4b40` as a note, and a
  comment in `internal/toolchain/toolchain.go` no longer names the private
  repository. Tests and outputs are unchanged upstream.
- **Main `7af1fd4` (2026-10-31, E162 and E163: D2).** The tree was then
  updated to main `7af1fd4` of spinel-bpf-mlir, upstream's `8b20ffa..7af1fd4`
  diff over the imported paths: 23 files, 20 taken as they are and 3 merged
  with their local changes, which are kept unchanged (`e133_test.go`'s
  checkout lookup, the note in `examples/bcc/PROVENANCE.md` and the libbpf and
  zlib variables in `scripts/build-bml-test.sh`). Upstream translated
  `examples/bcc/README.md` and `PROVENANCE.md` (E162), the messages of 14
  scripts and two bcc examples' printed text (E163), and renamed the bcc wave
  marks to English (`2-done`, `3-done`, `wave`), with the four tests that read
  them (e133, e140, e150, e159) and `testdata/verified.tsv` in the same
  change. Kept in Japanese upstream: the U+30FB KATAKANA MIDDLE DOT in four Go diagnostics and the
  tokens that `check-version-doc.sh` reads. Upstream's experiment records
  (`docs/`) are not imported.
- **Main `e14acc0` and bml `d879745` (2026-10-31, E164).** The tree was then
  updated to main `e14acc0faae26d397423ad9adf2595b3b9c2d8aa` of spinel-bpf-mlir, which takes bml
  `d879745d2f20d65a3e90c8bf6cb04586304024a9` (bml E059: its user-facing texts in English).
  - spinel-bpf-mlir's `7af1fd4..e14acc0` diff over the imported paths, 4 files, applied as it is:
    the bml pin string in `internal/version/version.go` and in the two `--version` expectations
    (`form_dev_test.go`, `form_public_test.go`), and 289 rows added to `testdata/verified.tsv`.
    Its README, tutorial and experiment records are not imported.
  - bml's `fae2194..d879745` diff over the imported paths, 2 files: `src/abi/object.c`'s
    `schema_hint` applied as it is, and in `scripts/build-libs.sh` the four stop messages and the
    four lines of the generated NOTICE text, merged with the local `BML_*_DIR` change, which is
    kept unchanged.
  - bml's four gitlinks are unchanged, so `third_party/PINS` keeps its values.
- **The public releases, spinel-bpf-mlir v0.9.0 and bpf-mlir-loader v0.1.0 (2026-11-11).** The two projects were released publicly on 2026-11-11, and the 2026-11-10 decision to import the new bml after that release was then carried out (relayed by the bpf-mlir coordinator).
  - spinel-bpf-mlir v0.9.0, the GitHub repository `yuskesh/spinel-bpf-mlir`, tag object `d13b51d3a7c9ed5cbf3cde355c7f7d92cb412035`, commit `698e63197fe49bfb2787fc62a17f396c8e2cdaff`. Its `SOURCE_VERSION` names `source_commit=c56a491510120b555c1f05db422fbdfa6eec72d1`, a development commit.
  - A correction to v0.9.0: its own `go.sum` records go-bpf-mlir v0.19.0 as `h1:qG/7HB+j…`, the sum of an earlier build of that version; sum.golang.org records `h1:3/dRMc4W1o/4d31ipJYJ8GpzQvwqzxIggKN2lVJDWlE=`, and a clean `go mod download` of v0.9.0 stops with a checksum mismatch. The export here writes the sum.golang.org value (`tools/dist/manifest.json`). Upstream released v0.9.1 with that fix the same day (below), and it is now the named source.
  - bpf-mlir-loader v0.1.0, https://github.com/yuskesh/bpf-mlir-loader, tag object `e94e3fe1a39ad0ee7f9dcec4e0a2c2522fde3dce`, commit `0e72c24f394edeac2ce16fdbcf11ee66491737d5`, with `source_commit=41ec56f1d3df74e8ac56aec1e74f6a51c83a6bbc`.
  - The module path of spinel-bpf-mlir's repository is written here without its host: the export rewrites that path in Go code and refuses it anywhere else.
  - The public trees are one-way exports of those development commits. Comments and experiment numbers are removed, and most tests and scripts are left out: of the imported paths, 444 tracked files here are not in spinel-bpf-mlir v0.9.0, and 202 are not in bpf-mlir-loader v0.1.0.
  - This repository builds and tests the development shape, so the content imported is the development tree at the two source commits:
    - upstream's `e14acc0..c56a4915` diff over the imported paths, 91 files (15 new, 76 changed). The 48 generated example outputs among its 139 files are not imported.
    - bml's `d879745..41ec56f1` diff, 399 files (288 new, 111 changed).
  - Three-way merges kept the local changes in four bml scripts:
    - `build-libs.sh`: the `BML_*_DIR` variables, now also inside upstream's new `step libbpf` line;
    - `srcs.sh`: the `"$HERE"/test/oracle` spelling, with upstream's English message;
    - `build-oracles.sh` and `gate.sh`: merged cleanly.

    No other local change overlapped the diff.
  - The export (`tools/dist/manifest.json`) also leaves out the development VM gate (`scripts/gate-vm{,-guest,-judge}.sh`), `cmd/spinelbpf/e167_test.go` (it reads the development `.gitmodules`) and two bml scripts that need the excluded `test/oracle` (`gen-btfexact-copy.sh`, `unknown-probes.sh`); `scan.public_repos` names the four repositories made public on 2026-11-11 (the bpf-mlir coordinator).
  - Checked by machine, before the local changes of this update: every file of the imported paths at the two source commits (the blob and the mode from `git ls-tree`) equals this tree, except the local changes.
    - Those are 6 files of spinel-bpf-mlir and 22 of bml.
    - The same files are 1,188 for spinel-bpf-mlir, plus 384 generated outputs not imported, and 642 for bml.
    - No file is missing, and none is extra.
  - From the public tags: spinel-bpf-mlir's `LICENSE` (Apache-2.0) and `NOTICE`, and bml's `LICENSE`, `NOTICE` and `LICENSES/` (the licence texts of libbpf, elfutils libelf and zlib). Both projects are now Apache-2.0 WITH LLVM-exception; `docs/imports.tsv` says so.
  - The pins:
    - Both sources now pin `41b188568cb36a15d4c185d5f72027267b3fa544` of bpf-mlir's development tree (E166), the source of the public bpf-mlir v1.21.0, as the development compiler. bml's libbpf, elfutils and zlib gitlinks are unchanged.
    - The public bpf-mlir v1.21.0 (commit `e5e439a0`) names the same commit as its `source_commit`, and `third_party/PINS` records it in all three rows.
    - The development Go module is bpf-mlir's, at `v1.19.1-0.20261110080538-41b188568cb3`.
  - Local changes made in this update:
    - `cmd/spinelbpf/e165_test.go`'s `git grep` leaves out `third_party/bpf-mlir-loader`, which is a submodule upstream.
    - Five new bml scripts that compare with Go oracles call `tools/oracle/gate`: `scripts/{reader-unit,target-rows-unit,unknown-probes,p152-unit,p152-preroot}.sh`.
    - `scripts/check-mutation-inventory.sh` spells `"$HERE"/test/oracle`, as `srcs.sh` does.
  - The VM and root files of this update are kept as files and are not run: spinel-bpf-mlir's `scripts/gate-vm*.sh` and root-test lists, and bml's `scripts/p152-*`, `gate-vm*.sh` and `virtme-run` wrappers.
- **spinel-bpf-mlir v0.9.1 (2026-11-11).** Upstream released v0.9.1, which corrects v0.9.0's go.sum: the GitHub repository `yuskesh/spinel-bpf-mlir`, tag object `ae06181f72e29bbb28739572d7948bad4b34e0c5`, commit `511781de0816b07bafb2ec48917b6b44443ed8da`, with `source_commit=0e83966a07fc351102eb9615d14e62011d3ff112`. Its go.sum records go-bpf-mlir v0.19.0 as `h1:3/dRMc4W…`, the sum.golang.org value the export already writes.
  - The update is upstream's `c56a4915..0e83966a` diff over the imported paths (E172): 52 files, of which 4 are taken as they are (the version string in `internal/version/version.go`, the two `--version` expectations in `form_dev_test.go` and `form_public_test.go`, and `examples/bcc/artefacts.sha256`). The other 48 are generated example outputs (the second line of each `.mlir`), which are not imported. No local change overlapped.
  - Checked by machine as before: every file of the imported paths at `0e83966a` equals this tree except the 7 locally changed files (1,187 the same, 384 generated outputs not imported, none missing or extra). bml is unchanged (`41ec56f1`, bpf-mlir-loader v0.1.0), and so are the pins.
- **The tools' own chain.** The 28 tools under `examples/bcc/` were written
  for spinel-bpf-mlir from spinel-ebpf `23fa4b0`'s `tools/<tool>.rb`. That
  is the revision already imported here (above), and all 28 originals are
  in `tools/ebpf/tools/` as the same blobs `examples/bcc/PROVENANCE.md`
  names. bcc itself is a reference for names and meaning; spinel-bpf-mlir
  copied no bcc code.

| Original | Local |
|---|---|
| spinel-bpf-mlir `{cmd,examples,internal,packaging,ruby,scripts}/`, `go.mod`, `go.sum`, `.gitignore` | `tools/spinel-bpf-mlir/` (same layout) |
| bml `{cmd,include,scripts,shim,src,test}/`, `.gitignore` | `tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/` (the path spinel-bpf-mlir's driver expects) |

- **Not imported:**
  - both projects' `docs/` (experiment records, plans and release notes), `CLAUDE.md` and `README.md`;
  - spinel-bpf-mlir's `third_party/` submodules: bpf-mlir and Spinel;
  - bml's own submodules: bpf-mlir, libbpf, elfutils and zlib;
  - the generated outputs committed under `examples/`: for each of the 41 examples, the `.mlir`, `.schema.json`, `.maps.json`, `.domain.json`, `.bpf.o`, `.compile_warnings.txt`, `_embed.S` and `_embed.o`, which is 328 files at v0.7.0 and 384 at v0.8.0 (48 examples). The 224 of `examples/bcc/` at v0.7.0, 280 at v0.8.0, are exactly the files `examples/bcc/artefacts.sha256` lists.
    - They are regenerated here, not copied.
    - `artefacts.sha256` itself is kept: it is the predecessor's record of what it produced, and comparing with it is an oracle.
- **Kept as files:** the uprobe targets, `examples/greetwatch/target/greeter` and `internal/frontend/testdata/uprobe/target/{cfix,gfix,mfix,pfix}` (the last three from v0.8.0). They are compiled C fixtures, with their sources and `SHA256SUMS` beside them, that the programs attach to. They are inputs, not outputs of the frontend. `scripts/build-uprobe-fixtures.sh --check` rebuilds and compares them.
- **Dependencies, user-local** ([installation record](toolchains/spinel-bpf-mlir-deps/INSTALLATION-RECORD.md)):
  - Go 1.27.3;
  - bpf-mlir's development tree at `41b188568` (the source of the public bpf-mlir v1.21.0, `e5e439a0`), whose `ebpf-compile` both projects pin since `c56a4915` and bml `41ec56f1` (`ab0db4b40`, an unreleased development commit, from main 9b914a8 to `e14acc0`, go/v1.18.0, `3bdd550e`, from v0.8.0, and go/v1.15.0, `99d631a5`, before). spinel-mlir's consumer pinned and was built against `ab0db4b40` until E084 (below);
  - libbpf v1.7.0, zlib v1.3.2 and elfutils 0.196, at the commits bml pins;
  - LLVM 23.1.1.
  - The Spinel is this repository's pin. The Go modules (bpf-mlir's development Go module at v1.19.1-0.20261028231217-ab0db4b40c05, `cilium/ebpf` v0.22.0, `x/sys` v0.43.0) are checked against `go.sum`. The published tree uses go-bpf-mlir v0.18.0 instead, with `cilium/ebpf` v0.22.1-0.20261027100858-b5a5a86f850a and `x/sys` v0.49.0 (the manifest's go.mod rewrite).
- **Licence.** Since their public releases (2026-11-11), spinel-bpf-mlir and bml are Apache-2.0 WITH LLVM-exception, with `LICENSE` and `NOTICE` files, imported (above). Before that, neither stated a licence, and every path was `none-stated` in `docs/imports.tsv`. The third-party libraries bml links keep their own terms; they are not vendored, and their licences are in the installation record.
- **Local changes**, listed in `tools/spinel-bpf-mlir/README.md`:
  - `TestBccProvenance` checks the 35 tools' source blobs against this repository's `tools/ebpf/`, not a spinel-ebpf checkout;
  - the driver's check that its bpf-mlir and bml's agree reads `third_party/PINS` (written here) in place of the two gitlinks;
  - bml's `scripts/build-libs.sh` takes its three sources from `BML_ZLIB_DIR`, `BML_ELFUTILS_DIR` and `BML_LIBBPF_DIR`.
- **Call-signs replaced by roles (2026-11-16, pre-public list).** In 29 imported files, the call-signs of the agents who asked for, reviewed or checked a change are replaced by roles ("the bpf-mlir coordinator", "the bpf-mlir reviewer", "a bpf-mlir implementer"); a comment rewritten this way became English. The fact each comment records is kept. `cmd/spinelbpf/e168_test.go` builds its planted call-sign at run time, with a comment saying why, so its detector still has one to find (with the detector's call-sign pattern broken, the test fails). Fixing these upstream and importing again is optional and comes after publication. Paths are under `tools/spinel-bpf-mlir/`:

  | File | Upstream release | Local change |
  |---|---|---|
  | `cmd/spinelbpf/e105_test.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `cmd/spinelbpf/e106_test.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `cmd/spinelbpf/e133_test.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `cmd/spinelbpf/e136_test.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `cmd/spinelbpf/e137_test.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `cmd/spinelbpf/e140_test.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `cmd/spinelbpf/e156_test.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `cmd/spinelbpf/e165_test.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `cmd/spinelbpf/e168_test.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `cmd/spinelbpf/rootlock_test.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `examples/bcc/PROVENANCE.md` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `examples/bcc/README.md` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `internal/frontend/e158_test.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `internal/frontend/fmodret.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `internal/toolchain/pin_public_test.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `internal/toolchain/pin_release.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `internal/toolchain/toolchain.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `internal/toolchain/toolchain_test.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `internal/version/version_public_test.go` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `scripts/check-sh-dialect.sh` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `scripts/lib/guest-only.sh` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `scripts/lib/rootlock.sh` | spinel-bpf-mlir v0.9.1 (source `0e83966a`) | call-signs replaced by roles |
  | `third_party/bpf-mlir-loader/scripts/gate-mode.sh` | bpf-mlir-loader v0.1.0 (source `41ec56f1`) | call-signs replaced by roles |
  | `third_party/bpf-mlir-loader/scripts/gate-vm-unit.sh` | bpf-mlir-loader v0.1.0 (source `41ec56f1`) | call-signs replaced by roles |
  | `third_party/bpf-mlir-loader/scripts/gate-vm.sh` | bpf-mlir-loader v0.1.0 (source `41ec56f1`) | call-signs replaced by roles |
  | `third_party/bpf-mlir-loader/scripts/live-target.sh` | bpf-mlir-loader v0.1.0 (source `41ec56f1`) | call-signs replaced by roles |
  | `third_party/bpf-mlir-loader/src/req/uprobe.c` | bpf-mlir-loader v0.1.0 (source `41ec56f1`) | call-signs replaced by roles |
  | `third_party/bpf-mlir-loader/test/abi/own_ids_unit.c` | bpf-mlir-loader v0.1.0 (source `41ec56f1`) | call-signs replaced by roles |
  | `third_party/bpf-mlir-loader/test/abi/run_own.h` | bpf-mlir-loader v0.1.0 (source `41ec56f1`) | call-signs replaced by roles |
- **The driver's Spinel check, not changed yet.** It still requires `086d514d`, which this repository's pin is not. How the frontend route is taken is the owner's decision.
- **Kept as files, not run:**
  - the 13 VM tests that boot `$HOME/kernel-build` images, named in the README and run only with `SPINELBPF_VM=1`;
  - the scripts that need the absent submodules or another project, including bml's oracle and differential scripts. v0.8.0's bml adds two differentials, `diff-split-dwarf.sh` and `diff-uprobe-offset.sh`; both are gated like the others, and `gen-uprobe-offset-copy.sh` writes `"$HERE"/test/oracle` as `srcs.sh` does.

## spinel-mlir's consumer: the BPF side from spinel_facts v2 (2026-10-26)

Imported as one unit on `feat/bcc-import`, for the owner's decision of
2026-10-26: the bcc tools' BPF side comes from this repository's
spinel_facts v2 through spinel-mlir's consumer, with no Go frontend at this
pin.

- **Source.** spinel-mlir (the bpf-mlir project's; it has no public remote), main `7db284d`. It is the first tip with both of the following, so it is one revision for the batch:
  - E076 (`41e4f6c`): the analysis-only `integers.enum_copy` in the v2 contract, and the consumer's shape check;
  - E075: the consumer's public outputs, `--emit-dir` and `--inspect-dir`.
  - It was read only, through `git archive`, and was not modified.

| Original | Local |
|---|---|
| `CMakeLists.txt`, `cmake/`, `include/`, `lib/`, `tools/`, `tests/`, `test/`, `scripts/`, `.gitignore` | `tools/spinel-mlir/` (same layout) |
| `docs/spinel_facts.md` | `third_party/spinel-mlir/spinel_facts.md`, refreshed (Patch 2 above had `3accdcd`'s) |

- **Not imported:**
  - `docs/` (experiment records, plans, researches) and `CLAUDE.md`;
  - `build.sh`, which makes a Python venv for lit;
  - `patches/` and `SPINEL_MLIR_PATCHES.md`, already here as the vendor fork and the copy of Patch 2;
  - the submodules;
  - `test/lit.cfg.py` and `test/lit.site.cfg.py.in`: lit is Python, and the RUN lines are read by a runner here instead;
  - eight experiment scripts that read the source machine's scratch captures (a scratch cache under its home directory) and that no test or build file uses:
    - `scripts/{audit-loop-locals,measure-e024-extra,measure-group-a,measure-group-b,measure-group-e,packet-merged-facts,regress-group-a-for-b}.rb`;
    - `tests/capture-named-corpus.rb`.
- **f96ac6d (2026-10-27).** The consumer was then updated to main `f96ac6da76cc9d494c78b947b5c1c6ce723a42ea` (E077 to E080: tracepoint array copies, embedded kernel struct paths with the typing probe, uprobes on system libraries, `:ptr`, `:user_buf` and `R.output_buf`), with spinel-bpf-mlir v0.8.0, on the owner's decision of 2026-10-27. The update is upstream's `7db284d..f96ac6d` diff over the imported paths, 65 files, applied as it is. Two new scripts are not imported: `tests/producer/typing-probe-{c,v1}-default.rb`, which run binaries under the source machine's scratch directory. The consumer pins bpf-mlir go/v1.18.0 (`3bdd550e`) from this revision.
- **The bpf-mlir pin of `76ff05f` (2026-10-30, stage PU).** spinel-mlir main `76ff05f42e34aeb240cfa60628387f367146e366` (E081) moves the consumer's bpf-mlir pin to `ab0db4b40`, an unreleased commit of bpf-mlir's development tree; its consumer source is unchanged. Here, the two pin lines of that diff are applied: `scripts/batch-compare.rb` (an oracle script, not run) and `scripts/build-consumer-sanitizers.sh`. The consumer is built against `ab0db4b40`, the commit spinel-bpf-mlir 9b914a8 pins too. One local change in `CMakeLists.txt` lets a bpf-mlir source release (no git) give its commit through `SOURCE_VERSION`. E081's other changes are its experiment records and `scripts/lib/corpus-contracts.json` (the corpus of its oracle comparison); they are not imported.
- **E082 (2026-10-30, stage PF).** spinel-mlir main `c86ce1aef1d90414140e7cf16b91d27c2a9b99c8` (the merge of E082, branch tip `66d68785`, into `76ff05f4`) neutralises the fixtures' source paths and lets the output-str tests read their uprobe target from a tracked capture dir. Its 55 changed files outside `docs/` are taken byte for byte: the 51 fixtures (the home-directory prefix of every source path becomes `/src/`), `tests/subprogram/enum-copy-controls.rb` (the E063 fixture's sha256 pin, moved with the fixture), `tests/consumer/OutputStrTest.cpp`, `output-str-run.rb` and `output-str-mutation.rb` (an optional `SOURCE_DIR` that file 0 is moved into). Its `CMakeLists.txt` hunks are applied on top of the local `SOURCE_VERSION` change. E082's experiment records are not imported.
  - The 17 output-str ctest entries stay oracle classes (`tests/spinel-mlir/tests.tsv`: 14 `oracle-records`, 3 `oracle-committed`), and none is routine. The `target/` dirs of `docs/experiments/results/E003/capture` that E082 points them at are not imported; their two binaries, `greeter` (sha256 `6aafa61f…`) and `cfix` (`a5808d55…`), are the same bytes as the tracked `tools/spinel-bpf-mlir/examples/greetwatch/target/greeter` and `tools/spinel-bpf-mlir/internal/frontend/testdata/uprobe/target/cfix`.
  - After E082 the three `oracle-committed` tests (output_str_in_kprobe, discard_dropped, discard_in_kprobe), whose oracle is in this tree, also need that capture dir's `target/cfix`; without it they stop with SB008.
  - The neutral prefix kept an agent's call-sign as a directory name (`/src/spinel-mlir-<call-sign>/…`, a bpf-mlir implementer's): over the 51 decompressed fixtures, 160,319 lines in 31 files matched the export's counted call-sign pattern.
  - **Local change (2026-11-16, pre-public list):** in those 31 fixtures (29 in `test/Inputs/`, `test/Inputs/E080/up-buf.mlir.gz` and `tests/percpu-record/width-wrap.mlir.gz`) the five old prefixes `/src/spinel-mlir-<call-sign>/`, one per file (9, 3, 7, 9 and 3 files), become `/src/spinel-mlir/`: one fixed-string replacement on the decompressed text, 164,820 replacements, then `gzip -n -9`. Checked per file: one old prefix and no `/src/spinel-mlir/` before; the same line count; the reverse replacement gives the old text byte for byte; no call-sign left; and `gzip -n -9` of the old text gives the old file. `tests/subprogram/enum-copy-controls.rb` pins the new E063 text (`e2d34989…`) and still checks the captured hash (`e6312c3b…`) on the reverse replacement, with a control that a changed byte outside the prefix is refused by the captured hash. The lowering prints only the basename of a source path, so no output changes.
- **E084 (2026-11-16, PG4 run 2).** spinel-mlir main `a8abbdc38e4ea56af5aeb23e6c37403e3e1ee758` (the merge of E084) ports the consumer to bpf-mlir v1.21.0 (public tag `e5e439a0`, whose SOURCE_VERSION names the source commit `41b188568`), whose `ebpf.program` takes a new `sleepable` unit attribute. Before it, the consumer did not compile against v1.21.0 (PG4 run 2). Its 5 changed files outside `docs/` are taken byte for byte; each was unchanged here since `c86ce1ae`:
  - `lib/Conversion/Consumer.cpp`, `tests/consumer/ArgvScopeTest.cpp` and `tests/consumer/FmodTerminalTest.cpp` pass `sleepable` false to `ProgramOp::create`;
  - `scripts/batch-compare.rb` and `scripts/build-consumer-sanitizers.sh` move their bpf-mlir pin from `ab0db4b40` to `41b188568`.
  - Not imported: `docs/experiments/E084*` and its results, as for every experiment record.
- **The contract copy.** `third_party/spinel-mlir/spinel_facts.md` is now verbatim from `f96ac6d` (Patch 3 above). Before that it was verbatim from `7db284d`: `3accdcd`'s text plus E076's ten lines, a section on the analysis-only attributes of analyzed nodes. `SPINEL_MLIR_PATCHES.md` and `patches/` are unchanged between the two revisions, so the vendor fork (`376a7727e`) stands.
- **E083 (2026-10-31, D2).** `third_party/spinel-mlir/spinel_facts.md` and `SPINEL_MLIR_PATCHES.md` are now verbatim from spinel-mlir main `4624b901f2cdef022b157fda88a15de068bff89e` (the merge of E083), which translates both into English; upstream checked that the multisets of their invariant parts (backticked spans, SHAs, Edoc and diagnostic IDs, dates and large numbers, paths, heading levels) are unchanged and no Japanese is left and that no code follows the change. `c86ce1ae..4624b901` changes nothing else outside `docs/`, so the consumer stays at `c86ce1ae` and the vendor fork's patches are unchanged. E083's experiment records are not imported.
  - **Local change (2026-11-16, pre-public list).** `third_party/spinel-mlir/spinel_facts.md` is no longer verbatim: in its sharing rules (line 4), the one agent call-sign is replaced by its role, "the bpf-mlir coordinator". The rest of the file, and `SPINEL_MLIR_PATCHES.md`, are still verbatim from `4624b901`.
- **Dependencies:** bpf-mlir go/v1.18.0 (`3bdd550e`; go/v1.15.0, `99d631a5`, before `f96ac6d`), its build and its source, user-local ([installation record](toolchains/spinel-bpf-mlir-deps/INSTALLATION-RECORD.md)), and LLVM / MLIR 23.1.1.
- **Licence.** spinel-mlir has chosen no licence, and has no licence or notice file. Every path was `none-stated` in `docs/imports.tsv`, for the owner to decide at publication (decision 0026); on 2026-11-20 the owner put them under the project licence, and they are `project-ported` (Project licence, at the top).

## The NPU lane's headers (2026-11-10)

`tools/npu/host/shim/` holds the POSIX shim headers the hosted runtime needs on picolibc. Files with the same name as in `vendor/spinel/lib/wasi` at the pin (`ed8c753a4`, MIT) are copies, `sys/ioctl.h` and `sys/socket.h` are extended here, and the rest are written here. NXP's converter and Neutron blobs are not imported: they are fetched outside the repository, as `tools/npu/README.md` says.

## spinel-modular as a submodule (2026-11-23)

`vendor/spinel-modular` is a submodule entry for `https://github.com/yuskesh/spinel-modular.git` at `f36772c`. spinel-modular is the product repository made from this repository's core and freestanding parts; the bare-metal full build (`tools/bare-full`, `tests/bare-full`) was moved there on 2026-11-23 and removed from this tree in the same change that added the submodule. This repository uses it in two places: `tests/bare-full/run.sh` runs its lane with this repository's `vendor/spinel`, and `tests/zephyr-full/run.sh` builds four programs of its `tests/bare-full/programs`. Nothing of it is copied here. Both repositories pin the same Spinel commit; the lane refuses to run when they differ. Its licence is Apache-2.0 WITH LLVM-exception, and it keeps its own notices. At this pin it no longer holds the RP2040 chip family or the second-stage boot described next: a chip family may live outside that repository, in a port directory named by `BAREMETAL_PORT_PATH`, and the RP2040's does.

## pico-sdk's second-stage boot for the RP2040 (2026-11-12)

The files this section names left this repository on 2026-11-23 with the bare-metal build, and are not in the pinned spinel-modular either (see above); the section is kept as the record of the import.

`tools/bare-full/chip/rp2040/boot2/generic_03h.S` (until 2026-11-23 `tools/bare-full/platform/rp2040-pico/boot2.S`) is the second-stage boot (boot2) the RP2040's boot ROM checks and runs from the first 256 bytes of flash ([decision 0037](decisions/0037-bare-metal-full.md)).

- **Source.** pico-sdk 2.3.1, the release tarball of `raspberrypi/pico-sdk` (sha256 `38d315b7…a2`, 2,728,129 bytes), read only and kept user-local as a reference: nothing of the SDK is built or linked.
- **Imported:** `src/rp2040/boot_stage2/boot2_generic_03h.S` and `src/rp2040/boot_stage2/asminclude/boot2_helpers/exit_from_boot2.S`, joined into one file. The SDK's header macros are replaced by the register addresses and values they name (`hardware/regs/ssi.h`, `addressmap.h`, `m0plus.h`); the instructions are otherwise the same. `LICENSE.pico-sdk.TXT` beside it is the SDK's `LICENSE.TXT`, verbatim.
- **Written here:** `chip.c`, `chip.yaml` and `link.ld` in `tools/bare-full/chip/rp2040/` (`board.c` and `link.ld` beside boot2 until 2026-11-23). Their register addresses and values are read from the SDK's `hardware/regs` headers; no SDK code is copied.
- **Not imported:** the SDK's `pad_checksum` script. `tools/bare-full/spinel-bare-full` computes the checksum itself, following the boot ROM's own check (CRC-32, polynomial `0x04c11db7`, most significant bit first, from `0xffffffff`, no final xor).
- **Licence.** BSD-3-Clause, "Copyright (c) 2019-2021 Raspberry Pi (Trading) Ltd." (the files' own lines, kept in `boot2/generic_03h.S`) and the SDK's `LICENSE.TXT`. A flash image built for `rp2040-pico` contains boot2 and carries those terms.

## The Zephyr full host's picolibc pieces (2026-11-12)

`tools/zephyr-full/host` ([decision 0038](decisions/0038-zephyr-posix-full.md)) uses two things of picolibc 1.8.10, the version in the Zephyr SDK 1.0.1.

- **Copied by the build, not tracked.** The CMake build extracts `libc_tinystdio_fdopen.c.o` and `libc_tinystdio_fileno.c.o` from the SDK's own `libc.a` (the one `arm-zephyr-eabi-gcc -mcpu=cortex-m33 -mthumb -specs=picolibc.specs -print-file-name=libc.a` names), renames their symbols with `objcopy` and links them into the image. Nothing of them is in the repository; an image carries them under picolibc's licence, as every image linked with that `libc.a` already does.
- **Written here after picolibc's layout.** `__freadahead` in `src/host.c` reads the first fields of picolibc's private `struct __file_bufio` (`newlib/libc/tinystdio/stdio-bufio.h` in picolibc 1.8.10, as Zephyr v4.4.2's `modules/lib/picolibc` has it): the field order and types are restated, no code is copied, and the build stops on any other picolibc version.
- **Licence.** picolibc's, BSD-3-Clause for those files ("Copyright © 2019 Keith Packard" for `fdopen.c` and `fileno.c`, "Copyright © 2022 Keith Packard" for `stdio-bufio.h`).
