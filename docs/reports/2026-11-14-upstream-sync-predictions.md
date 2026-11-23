# Upstream Spinel synchronisation, 2026-11-14: predictions

This page records what the synchronisation of `vendor/spinel` to upstream
Spinel is expected to do, written before any code changed. Results are
recorded later beside these predictions; a prediction is not rewritten after
its result is seen.

- Upstream revision taken: `f8ff019399539dfa41ad99d52fb9d11039905d73`
  (https://github.com/matz/spinel, 2026-11-14), fixed once at the start for
  both sides.
- The pin on `main` (`5217686a`) is `c23d82a7c`: 19 fork commits above
  upstream `e1d92f1e1`. The ARGV fill order (`3ac5c2853`, branch
  `argv-fill-order`) is one commit above it and joins this synchronisation.
- The read-only survey that sized this work (conflict counts, the bisects,
  the suite comparison on `020275b35`) is the first bpf-mlir implementer's survey report, kept
  outside the repository (the export refuses a scratch path). Between
  `020275b35` and `f8ff01939` upstream added 9 commits (22 files, Hash value
  storage, a typed Array store's root, a native-name refusal).
- Two sides: the fork (branch `sync/upstream-f8ff0193`, the first bpf-mlir implementer) and this
  repository (branch `sync/upstream-spinel`, the second bpf-mlir implementer). No CRuby oracle runs.
  The full suite set runs once at the end; until then only
  `tools/test/affected.rb` selections.

## The fork side

### What moves

1. **The stack.** A new branch from `f8ff01939` carries, in the old order,
   the 18 fork commits from `31ae75c6d` to `c23d82a7c`, then the ARGV fill
   order (`3ac5c2853`), then one new commit (item 6). `047a30699`
   (`--gc=none`) is dropped: it is upstream's `ba5891e0a`, already in
   `f8ff01939` with upstream's later rework (no roots under `--gc=none`, the
   separate `libspinel_rt_nogc.a`). Each replayed commit keeps its subject and
   author and gains a dated note naming what conflicted and how it was
   resolved, as on 2026-10-18.
2. **Conflicts.** About 40 conflict regions, within ±10 of the survey's 41
   on `020275b35`, in the same files; the 9 newer upstream commits add none
   or few, since they touch Hash storage, which no fork commit edits. Two
   commits apply cleanly (`e978eeb37`, `bc3cd66c2`).
3. **The abort entry (`bc050e4e6`).** Upstream rewrote `sp_raise_cls`'s
   uncaught path (a user `#message`, the backtrace). The entry is re-written
   to share upstream's new uncaught tail rather than keep the old one. So
   `sp_abort_uncaught` prints what a normal uncaught raise of the same class
   and message prints at `f8ff01939`, which may differ from what it printed
   at `c23d82a7c`. Consumers that compare its stderr
   (`native-core-arith`, `doom-abort-controls`) may need new expectations;
   that is this repository's side.
4. **String FFI borrowing (`5630a4e28`).** Upstream's String model changed
   since `e1d92f1e1` (one String mode, `44119ab30`; U2, `e3f737d2e`). The
   prediction is that the borrow needs adaptation beyond the conflict
   regions, not only a textual merge, and that after it the fork's
   `scripts/ffi-string-borrow-check.sh` passes with the same cases and
   reasons as at `c23d82a7c`. If the new model cannot give a call-duration
   mutable borrow without copying, the commit stops there and the question
   goes to the owner, rather than being weakened.
5. **`SP_GC_EVENTS` (`8e1ac9e2c`, `edb7761b7`, `c23d82a7c`).** Conflicts are
   against upstream's slab changes (`sp_gc.c`, `sp_slab.c`). The record's
   format and its event kinds do not change; `make events-runtime` builds.
6. **A new commit: the prune keeps the external roots.** Upstream
   `7bc3fe018` blanks methods nothing in the program names. The fork names
   methods from outside the program: `--analysis-root` methods (M2),
   `SPINEL_EXTERN_METHODS` names and `--core` identities. The new commit adds
   those names to the prune's `named` set, so they survive while every other
   unnamed method is pruned exactly as upstream prunes it. It carries a fork
   test: a def nothing calls survives when one of the three names it, and is
   blanked when none does.
7. **Effort.** One to one and a half agent-days for the stack (survey
   estimate).

### What must not move

1. **The default build is upstream's.** With no fork switch (no `--core`,
   no ledger request, no `SPINEL_EXTERN_METHODS`, no
   `--no-loop-sig-poll`, no `:str_inout` spec, no `--emit-mlir`,
   `--analysis-root` or `--emit-typing-probe`, no `-DSP_GC_EVENTS`), the
   C generated for every program in upstream's `test/` is byte-identical to
   plain `f8ff01939`'s, except where the ARGV fill order rewrites the ARGV
   setup. This is checked by compiling the corpus with both compilers.
2. **Upstream's own tests.** `make test` at the fork tip passes and fails
   the same targets as plain `f8ff01939`, measured on the same host.
   (`ext-cruby-test` skips itself: the host's `ruby` is 3.3, not the 4.0
   it requires.)
3. **The fork's checks.** `make test-core-seam` passes all its cases (28 at
   `c23d82a7c`); `scripts/ffi-string-borrow-check.sh` passes;
   `make events-runtime` builds; upstream's `gc-none-test` passes; the new
   prune test passes. This repository's `tests/spinel-fork/argv-fill.sh`
   passes against the fork build.
4. **The contract reader still links without `main.o`**
   (`tools/contract/build.sh`), with no warnings.
5. **Nothing is pushed** to `yuskesh/spinel` until the owner confirms; the
   old branches are not rewritten or deleted.

### Addendum, 2026-11-14, before any result: the vendor check set

"What must not move" item 2 named `make test`. Its prerequisites include
`cext-compiler-test`, which runs a program under CRuby and compares
(`test/cext/compiler-test.rb`), so it is a CRuby oracle. It ran twice, on
plain `f8ff01939` and on the old stack `3ac5c2853`, before this was noticed;
those runs are not evidence. The vendor check set is instead
`make -k test-run` (whose `ext-cruby-test` skips itself on the host's Ruby
3.3), `make test-core-seam`, `scripts/ffi-string-borrow-check.sh` and
`make events-runtime`, run with a `ruby` guard first on `PATH` that refuses
every call but a `tools/*.rb` script or a `-e` one-liner and counts the
refusals. Item 2 reads: `make -k test-run` at the fork tip passes and fails
the same targets as plain `f8ff01939`, with no refused `ruby` call.

## This repository's side

Written before any change on branch `sync/upstream-spinel` (from `main`
`5217686a`) and before any suite ran against `f8ff01939`. The survey's
measurements were on `020275b35`; the 9 newer upstream commits are predicted
to change none of them.

### What moves

1. **The gitlink.** `vendor/spinel` moves from `c23d82a7c` to the fork tip
   built on `f8ff01939` (the fork side above). The source stamps that pin the
   vendor sources are re-recorded; that is mechanical, and every stamp that
   names a vendor file changes, and only those.
2. **The stamp tool reads a worktree's own vendor store.**
   `tools/test/source-stamp.rb` reads the pinned vendor tree only from the
   shared `.git/modules/vendor/spinel`. A worktree whose submodule has its own
   git directory (this one) is refused with "not a tree object" for any
   commit the shared store lacks. The tool will read the vendor checkout's
   own git directory first and fall back to the shared store. With the shared
   store, every stamp it writes and checks is unchanged.
3. **The contract reader: the prune (upstream `7bc3fe018`).** A new
   recognised rewrite, like the 2026-10-18 dead branch: a parsed `DefNode`
   whose every node is a `NilNode` in the nodes face, and whose name no other
   node of the program holds. With it, and with the fork's keep list (fork
   item 6) for the external roots, the 28 `kind-mismatch … 'DefNode' nodes
   'NilNode'` refusals go, and these rows return to their outcome at the pin:
   e081 c1, c2, c3, c4 and k6; e083 c4; e084 n1, n2, n3 and n5.
4. **The contract reader: the paren peel (upstream `f49a94feb`).** A second
   recognised rewrite: a `ParenthesesNode` that the analysis empties around
   a desugared operand. The 7 `kind-mismatch … 'ParenthesesNode' nodes
   'NilNode'` refusals go; e079 c01 (fs-emit and fs-grad) and e084
   c1_kernel and c1_fsgrad return to their outcome at the pin.
5. **The e084 reject table flips one row.** `n4_loop_mul` (a Float assigned
   in a `while` to a local first typed by its Integer growth) is accepted
   after upstream `bd53f5938`. Its reject row is replaced by an accept case
   of the same program in the lane's accept tables, and no other row of that
   table changes.
6. **native-core** returns from "the vendor does not carry the --core seam"
   to its pin count (8 pass, 0 fail) once the fork tip carries the seam.
7. **The abort entry's stderr.** If the fork's `sp_abort_uncaught` now
   prints upstream's new uncaught report (fork item 3),
   `tests/native-core/arith.sh` and the doom abort controls get new
   expected text in the same commit as the gitlink, each difference named.
   Their exit statuses do not change.
8. **The runtime bitcode member lists** (`tools/llvm/build_rt_bc.sh`, used by
   the llvm and grad suites and e084's host leg) change if upstream added,
   removed or renamed runtime translation units since `e1d92f1e1`; the list
   is re-derived from the vendor Makefile, not edited by hand.
9. **Documentation.** `docs/provenance.md` gets an "Upstream
   synchronisation, 2026-11-14" section (revision, commit count, stack,
   resolutions, validation); `docs/spinel-patches.md` gets the new stack and
   the dropped `--gc=none` commit; `SPINEL_KEEP_UNNAMED` is not left set on
   any tracked path.

### What must not move

1. **subset-tables** 12/12 and **core-run** 33/0, as at the pin (Prism is
   1.9.0 at both ends).
2. **The reader stays exact.** A `DefNode` blanked while another node of the
   program still holds its name, a def only partly `NilNode`, and a
   `ParenthesesNode` turned into anything but `NilNode` are still
   `kind-mismatch`. Each new rewrite has a negative control in the reader's
   own tests.
3. **Freestanding.** After items 3 to 5, every row has its outcome at the
   pin, apart from `n4_loop_mul`. The rows behind `/opt/llvm-23.1.1`'s
   `ld.lld` / `wasm-ld` (which cannot load `libicui18n.so.70` on this host)
   and the board rows fail or are NOT RUN exactly as at the pin.
4. **`--gc=none` callers.** `tests/edge/arena.sh` and `tests/gc-arena` go
   through the compiler driver and pass unchanged. No file that links
   `libspinel_rt.a` by hand links a `--gc=none` program, so none needs
   upstream's `libspinel_rt_nogc.a` (checked by reading each of them).
5. **The wide suites at the end** (doom and doom-core, ebpf, wasm, the apps,
   gcmon and gcviz, raster) pass as they do at the pin. Where one does not,
   the failure is named with its cause and is either adapted here or taken
   to the owner. The prediction is that the `SP_GC_EVENTS` record format
   (gcmon, gcviz) and the `:str_inout` borrow (raster) need no change here.
6. **No CRuby oracle runs**, and nothing is pushed or merged to `main`.

## Results: this repository's side

Recorded after the predictions above, which are left as written. The final
full run was at `949ac591` (on `main` `4cf6d188`, 0042 stage 2), with
`vendor/spinel` at the fork's `4e0a59bd9`. It ran once, with
doom-loop-reports last. It covered 84 suites:

| Outcome | Suites |
| --- | --- |
| Pass | 73, among them doom-loop-reports (102 / 0), spinel-bpf-mlir (Go 1.27), ebpf-go (Go 1.25), doom-net-view, gcviz, edge, zephyr-full, bare-full, native-core-arith (99 / 0) |
| Pass with skips only (exit 2, nothing failed) | 6: shader, compute, raster, npu, npu-stm32mp2, ghostty-terminal |
| Known failure | 1: raster-string-borrow (`tools/test/known.tsv`) |
| Fail for the environment, the same on `main` | 3: freestanding (e084's host leg), doom-profile, app-stress |
| Fail from `main`, not this synchronisation | 1: doom-source-pack |

For each suite that failed, the first pass was compared with a baseline:
`origin/main` `d5b54a7f` (vendor `baddd25a9`), built in its own worktree and
run with the same environment. A suite that fails on both is the
environment's, not the synchronisation's.

### Against each prediction

- **What moves 1 (gitlink, stamps).** As predicted.
- **2 (the stamp tool's store).** As predicted (`21d69d56`). Not predicted:
  `tests/source-stamp` needed the same store order (`5267c4eb`).
- **3 and 4 (prune, paren peel in the reader).** As predicted (`3e593f56`),
  with the suite `contract-rewrites`. The peel also reached three readers
  the predictions did not name:
  - the CORE checker (`9385cc61`, native-core-arith);
  - spinel-bpf-mlir's Go frontend (`0cd88175`);
  - the shader tools' cross-check (`06e383e1`, shader and compute).

  Each admits exactly the peel shape, and the pair reads the type of the
  expression in its place.
- **5 (e084 `n4_loop_mul`).** Already on `main` before this branch. The
  branch's own commit was dropped at the rebase.
- **6 (native-core).** As predicted.
- **7 (abort stderr).** No new expected text was needed.
  `doom-abort-controls` passes (6 / 0) and `native-core-arith` passes
  (99 / 0) with their expectations unchanged. native-core-arith's failure in
  the first pass was the paren peel (above), not the abort text.
- **8 (bitcode member lists).** Not exercised. No llvm or grad suite is in
  `tools/test/tests.tsv`. e084's host leg needs the runtime bitcode
  `tools/llvm/build/libspinel_rt_lto.a`, which this host has not built (the
  same on `main`). The member list was not re-derived.
- **9 (docs).** As predicted. `SPINEL_KEEP_UNNAMED` is set on no tracked
  path; `tests/contract/rewrites.sh` only unsets it.
- **Must not move 1 to 3.** As predicted:
  - subset-tables passes 12 / 12 and core-run 33 / 0.
  - contract-rewrites (12 / 0) carries each rewrite's negative controls.
  - Every freestanding lane has 0 failures. e084 exits 1 only because its
    host leg needs the runtime bitcode (above), as on `main`.
- **Must not move 4 (`--gc=none` callers).** `tests/edge/arena.sh` passes,
  but not unchanged. Its known catch/throw defect no longer reproduces at
  `f8ff01939`: catch_int prints Ruby's 1 on both builds. The case is now an
  ordinary check (`29311d82`).
- **Must not move 5 (the wide suites).** Not as predicted. Upstream now
  stores a String variable as a mutable handle (`SP_STR_HDL`,
  `sp_String *`); a StrArray ivar becomes a PolyArray. Four outcomes follow
  from that, and three runtime changes needed small host additions:
  - gcviz: line 27's Strings are handle objects, and nothing in the example
    allocates a string. Re-pinned (`506d28cb`).
  - raster-string-borrow: `GpuRaster#frame` copies `@wad` (an `in` buffer)
    on every GPU frame. This is accepted for this synchronisation as a known
    failure (`f8687851`, the lead's decision). A borrow route is an open
    follow-up on the fork.
  - doom-fork-compat (B14): `puts(*a)` truncated a binary String at its NUL.
    Fixed on the fork (`dedf05317`, patch entry 24, regression test
    `test/puts_splat_binary_string.rb`).
  - doom-net-view: a String stored into an Array held in a Hash did not
    write through, so the viewer lost every frame piece. The cause was found
    by bisecting. It is fixed on the fork (`4e0a59bd9`, patch entry 25,
    regression test `test/str_array_in_hash_store_aliases.rb`).
  - zephyr-full and bare-full: the runtime calls `getuid` and `getgid`
    (File::Stat, `c78f461dd`) and `isatty` (STDOUT write-through,
    `820b9a6a6`). The board hosts declare or stub them. `isatty` answers
    "not a terminal", which keeps the buffering they had (`8490a34d`,
    `8ae19c64`).
  - edge, edge-isolation, edge-arena: the wasm runtime imports `sock_recv`.
    The shim answers ENOSYS, as it does for `sock_send` (`3b9592ae`).
- **Must not move 6.** No CRuby oracle ran. Nothing was pushed or merged.

### Deviations from the predictions (not predicted)

- The CORE checker reads two new upstream AST fields, `DefNode.locals` and
  `CallNode.ignore_visibility`, each under an exact rule. It reads block
  parameter slots by their analysed name (`i__b<tag>`). The kernel names
  its roots to the reader with `spinel-typedump --keep-method` (`efd4923d`,
  suite `core-upstream-fields`).
- `spinel-fs-emit` keeps its two named refusals, the split file and the
  builtin change, through a fallback and a quiet retry (`079e7bfa`).
- The contract reader now refuses core-eligibility's two top-level prepend
  cases (exit 2, dangling-reference). That is one layer before the checker
  would give its verdict (`1d274b34`, the lead's decision (a)). Teaching the
  reader the shape is a possible later step with its own review.
- `tests/spinel-fork/argv-fill.sh` came from `feat/argv-fill-order`,
  re-pinned to the new ARGV line. This synchronisation absorbs that branch
  (`57a817d2`).
- The paren peel in three more readers, and the String-handle outcomes, are
  described above.
- Environment: the lane suites need:
  - `LD_LIBRARY_PATH` with ICU 70, for `/opt/llvm-23.1.1`'s linkers;
  - `IREE_COMPILE` and `NANOPB_DIR`;
  - `GO`: 1.27 for spinel-bpf-mlir, 1.25 for ebpf-go;
  - bml's archives;
  - a built `tools/spinel-mlir`.

### Not run, or failing for the environment

- freestanding: e084's host leg needs `tools/llvm/build/libspinel_rt_lto.a`
  (`tools/llvm/build_rt_bc.sh`), which is not built here. Every other lane
  passes, including e084's other 101 checks. The same on `main`.
- doom-profile: needs `SESSION_IMAGE`, DEMO1's session image. The same on
  `main`.
- app-stress: the firmware link finds no `core_produce.bc`. The same on
  `main`.
- Skips only:
  - shader: Metal, wgpu-native.
  - compute: CUDA, WebGPU.
  - raster: no GPU runtime.
  - npu: no `tflm_neutron` sample.
  - npu-stm32mp2: no cross toolchain.
  - ghostty-terminal: no Ghostty checkout.
- Board and oracle steps print NOT RUN, as at the pin.

### From `main`, not this synchronisation

doom-source-pack fails 1 of 103 checks: "and names the arithmetic it cannot
prove". The test appends `puts fixed_mul(1, 1)` to the packed core tree and
expects the driver to refuse `fixed_mul` for `unproved-arithmetic`.
`examples/doom/core/README.md` says the same.

The baseline's checker (`d5b54a7f`, before 0042 stage 2) was run on the same
input. It refuses for the 813 top-level constants (`binding-environment`) and
for `>>` (`unproved-arithmetic … for >>`). Since 0042 stage 2 (`d890b574`,
`<<` and `>>` on every CORE route), `>>` is proved and only the constants
remain. The refusal still holds, but its reason has changed, so the test and
the README need updating on `main`. This branch leaves both unchanged.

`main` has since fixed both (`2bf05f53`, source-pack's refusals after decision
0042). After the rebase below, doom-source-pack runs against this branch's
`vendor/spinel` and kernel and passes 104 of 104 checks.

### After the rebases onto `main`

`main` moved three times after the run above. Each time the branch was
rebased and only the affected suites were run again (`tools/test/affected.rb
--base <the tip before the rebase>`), not the full set.

- On `c2e4eac8`, 30 of 31 suites passed.
- On `289163f7` (0042 stage 4, the hosted prelude), the intrinsic cases failed
  with a dangling reference. Upstream `1782a9e13` adds version entries for
  calls that run before a method's first `def`, and these clashed with the
  prelude appended after the program. `main` fixed it at `a0a312d8` by putting
  the prelude before the program (`insertPrelude`). The fix is on `main`, not on
  this branch.
- On `88750448` (0041 stage 2 on top of `a0a312d8`), the
  `tools/test/tests.tsv` and `tools/test/affected.tsv` conflicts were resolved
  by taking both sides' rows and selections. The dist manifest was re-pinned.
  `Core/Input.cpp` merged on its own: the prelude goes first, followed by the
  `--keep-method` roots. `loadContract` takes both `withPrelude` and
  `keepMethods`.

`affected.rb --base` on the tip before the last rebase selected 48 rows. 44
of them ran. The three board rows need a board. doom-loop-reports runs once at
the end of the whole effort, not after each merge.

| Outcome | Suites |
| --- | --- |
| Pass | 43, among them doom-source-pack (104 / 0), freestanding (every lane, e084 included), native-core-arith, core-bitwise, core-intrinsics, core-upstream-fields, contract-rewrites, scratch, fiber, fiber-core, the app suites |
| Fail for the environment | 1: doom-profile (`SESSION_IMAGE`, as above) |

freestanding passes here because this run's worktree had the e084
prerequisites built: `tools/llvm/passes` (cmake and ninja, with
`LLVM_PREFIX`) and `tools/llvm/build_rt_bc.sh`.

### Open items

- raster-string-borrow's `@wad` copy per GPU frame: a borrow route, on the
  fork.
- Storing `nil` into a StrArray that is also held elsewhere still widens it
  into a copy the other holder does not see. It is the same on `baddd25a9`,
  so it is not from this synchronisation.
- The CORE checker does not check the fields of a block loop's `CallNode`.
  This predates the synchronisation.
- doom-source-pack on `main` (above): closed by `main`'s `2bf05f53`.
