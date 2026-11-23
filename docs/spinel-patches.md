# Spinel patches

Spinel Extended builds with the vendored Spinel fork (yuskesh/spinel), pinned
in `vendor/spinel` at `4e0a59bd999e614bd8b2ece72ec2b8d0cbbc5522`, the fork's
branch `sync/upstream-f8ff0193`. Since the upstream synchronisation of
2026-11-14 the pin is 23 commits above upstream Spinel
(https://github.com/matz/spinel) at
`f8ff019399539dfa41ad99d52fb9d11039905d73`, in the order
`git -C vendor/spinel log --reverse f8ff01939..4e0a59bd9` prints. The table
in [The 2026-11-14 synchronisation](#the-2026-11-14-synchronisation) maps
each of them to its entry below. Each entry says what the commit changes, why
this repository needs it, how it is switched on, and how it is tested. Where
the patches came from, and the dated history of each import and
synchronisation, is in [Dependency provenance](provenance.md#spinel-baseline).

The entries numbered 1 to 20 below were written for the previous pin,
`baddd25a9` on upstream `e1d92f1e1`; their headings keep that pin's commit
hashes. Entries 1 and 20 were backports of upstream commits, which
`f8ff01939` now contains, so they are no longer in the stack.

The first commit is upstream's own `--gc=none`, backported. The other 15 are
the fork's patches, each replayed on 2026-11-01 from the commit it names,
without the process-lifetime arena that the previous pin carried. The arena's
seven commits and its re-record are no longer in the stack; their record, and
why `--gc=none` replaces them, is in
[The arena replaced by upstream --gc=none](provenance.md#the-arena-replaced-by-upstream---gcnone-2026-11-01).

## The 2026-11-14 synchronisation

The fork's stack was replayed in one step onto upstream `f8ff01939`, on the
branch `sync/upstream-f8ff0193`. Every replayed commit's message ends with a
paragraph that starts "2026-11-14 upstream synchronisation onto f8ff01939:"
and says what conflicted and how it was resolved. The summary, the
predictions and the results are in
[Upstream synchronisation, 2026-11-14](provenance.md#upstream-synchronisation-2026-11-14).

- **Left the stack**: entry 1 (`--gc=none`, upstream `ba5891e0a`) and
  entry 20 (upstream `bd53f5938`). Upstream `f8ff01939` contains both.
- **Replayed**: entries 2 to 19, in the same order.
- **New**: five commits. One replays the ARGV fill order (`3ac5c2853`);
  one keeps the outside-named roots through upstream's new prune of unnamed
  methods; one resets the ARGV count before the fill. Entries 21 to 23 below.
  Two more came after this repository's first full suite run: upstream now
  makes a String local a mutable handle, and two runtime paths still took
  only the plain String tag. Entries 24 and 25 below.

`git diff --shortstat f8ff01939 4e0a59bd9`: 109 files changed, 3162
insertions, 48 deletions.

| # | commit | entry | replays | series | subject |
|---|---|---|---|---|---|
| 1 | `65e9150aa` | 2 | `31ae75c6d` | selected-root seam | core: give a CLI-selected root a real symbol and no body |
| 2 | `b621d92cb` | 3 | `2aef05bea` | selected-root seam | core: make the selection input fail closed |
| 3 | `521bc6a7d` | 4 | `d902817cd` | selected-root seam | core: create the mapping's temporary file exclusively, beside the destination |
| 4 | `632e969ac` | 5 | `4eb8bb13d` | selected-root seam | core: never remove the mapping's destination before replacing it |
| 5 | `e1c445c17` | 6 | `372f4be76` | input ledger | frontend: record the files actually opened, and write them on request |
| 6 | `ceba94ceb` | 7 | `9408dedb4` | input ledger | frontend: make the ledger opt-in, and publish it without destroying one |
| 7 | `911c466e6` | 8 | `e978eeb37` | input ledger | frontend: refuse a ledger for a run that recognised a load it did not satisfy |
| 8 | `d6d6ac9b7` | 9 | `716b7f553` | external methods | codegen: SPINEL_EXTERN_METHODS, external definitions for named top-level methods |
| 9 | `0ea04c295` | 10 | `bc050e4e6` | abort entry | runtime: add sp_abort_uncaught, an uncaught report no frame can catch |
| 10 | `408e75d84` | 11 | `b14139050` | loop signal polls | codegen: --no-loop-sig-poll, an opt-in build whose loops do not poll |
| 11 | `09e6f6415` | 12 | `5630a4e28` | String FFI borrowing | Add synchronous mutable String FFI borrowing |
| 12 | `92d3387a9` | 13 | `468c48b0d` | spinel-mlir | M1: opt-in generic MLIR transport (--emit-mlir=<path>) |
| 13 | `bcb5bdbf9` | 14 | `7c4cfb9f4` | spinel-mlir | M2: external analysis-root request (--analysis-root=METHOD:TYPE[,TYPE...]) |
| 14 | `e89f3781b` | 15 | `bc3cd66c2` | spinel-mlir | M3': original-file positions for this pin, derived from M3 |
| 15 | `180949bd9` | 16 | `ed8c753a4` | spinel-mlir | M4': spinel-mlir's typing probe (--emit-typing-probe), for this pin |
| 16 | `1a6a3030e` | 17 | `8e1ac9e2c` | GC events | runtime: SP_GC_EVENTS, an opt-in record of every slab slot's life |
| 17 | `7698bf0b7` | 18 | `edb7761b7` | GC events | runtime: SP_GC_EVENTS records the stack behind each allocation and collection |
| 18 | `ffbc653e8` | 19 | `c23d82a7c` | GC events | runtime: SP_GC_EVENTS records the blocks malloc'd outside the slab |
| 19 | `e72f8a112` | 21 | `3ac5c2853` | ARGV fill | codegen: count only the written ARGV slots in sp_argv.len |
| 20 | `f25a0222b` | 22 | — (new here) | prune keep list | analyze: the prune of unnamed methods keeps the roots named from outside |
| 21 | `b1b0702da` | 23 | — (new here) | ARGV fill | codegen: the ARGV fill starts from sp_argv.len = 0 |
| 22 | `dedf05317` | 24 | — (new here) | String handles | runtime: puts(*a) writes a String element by its byte length |
| 23 | `4e0a59bd9` | 25 | — (new here) | String handles | runtime: a String handle stored into a StrArray does not widen it |

## What every entry says

- **Commit**: the fork commit, its subject and the files it touches, and the
  commit it replays.
- **What and why**: what the diff does, and what in this repository uses it.
- **Switching it on**: the switch, and whether the default build's output is
  upstream's when the switch is off.
- **Rebase**: what conflicted when the replayed commit was itself replayed onto
  `e1d92f1e1` on 2026-10-18, and how it was resolved. The commit's own message
  carries the full note; [Upstream synchronisation, 2026-10-18](provenance.md#upstream-synchronisation-2026-10-18)
  has the summary. Commits written on `e1d92f1e1` or later had no rebase.
- **Replay without the arena**: what conflicted on 2026-11-01. Every conflict
  region held an arena block beside the commit's own lines, and only the arena
  lines were left out. Each message ends with one line saying so.
- **Tests**: the fork's own checks, and the suites of this repository that
  exercise the patch (`tools/test/tests.tsv` names, or the script path).
- **Upstream**: commit 1 is upstream's. None of the other 15 has been proposed
  upstream. Provenance records that nothing was reported upstream.

The facts below were read from each commit's diff. Where a commit message says
something the diff does not show, the entry follows the diff and says so.

## The 20 commits of the previous pin (`baddd25a9`)

| # | commit | replays | series | subject |
|---|---|---|---|---|
| 1 | `047a30699` | upstream `ba5891e0a` | `--gc=none` | --gc=none builds a program with no garbage collector |
| 2 | `31ae75c6d` | `e97e56074` | selected-root seam | core: give a CLI-selected root a real symbol and no body |
| 3 | `2aef05bea` | `69e678445` | selected-root seam | core: make the selection input fail closed |
| 4 | `d902817cd` | `4eccb455d` | selected-root seam | core: create the mapping's temporary file exclusively, beside the destination |
| 5 | `4eb8bb13d` | `5547a0385` | selected-root seam | core: never remove the mapping's destination before replacing it |
| 6 | `372f4be76` | `96c374f7e` | input ledger | frontend: record the files actually opened, and write them on request |
| 7 | `9408dedb4` | `198d0df82` | input ledger | frontend: make the ledger opt-in, and publish it without destroying one |
| 8 | `e978eeb37` | `0f58b2146` | input ledger | frontend: refuse a ledger for a run that recognised a load it did not satisfy |
| 9 | `716b7f553` | `bc51716ea` | external methods | codegen: SPINEL_EXTERN_METHODS, external definitions for named top-level methods |
| 10 | `bc050e4e6` | `3c4984057` | abort entry | runtime: add sp_abort_uncaught, an uncaught report no frame can catch |
| 11 | `b14139050` | `6aa5f6395` | loop signal polls | codegen: --no-loop-sig-poll, an opt-in build whose loops do not poll |
| 12 | `5630a4e28` | `ad4bb8c42` | String FFI borrowing | Add synchronous mutable String FFI borrowing |
| 13 | `468c48b0d` | `70c9f6650` | spinel-mlir | M1: opt-in generic MLIR transport (--emit-mlir=<path>) |
| 14 | `7c4cfb9f4` | `4bcb6d6a2` | spinel-mlir | M2: external analysis-root request (--analysis-root=METHOD:TYPE[,TYPE...]) |
| 15 | `bc3cd66c2` | `9c20d87a0` | spinel-mlir | M3': original-file positions for this pin, derived from M3 |
| 16 | `ed8c753a4` | `67fba6d34` | spinel-mlir | M4': spinel-mlir's typing probe (--emit-typing-probe), for this pin |
| 17 | `8e1ac9e2c` | — (new here) | GC events | runtime: SP_GC_EVENTS, an opt-in record of every slab slot's life |
| 18 | `edb7761b7` | — (new here) | GC events | runtime: SP_GC_EVENTS records the stack behind each allocation and collection |
| 19 | `c23d82a7c` | — (new here) | GC events | runtime: SP_GC_EVENTS records the blocks malloc'd outside the slab |
| 20 | `baddd25a9` | upstream `bd53f5938` | upstream backport | A local a while multiplies keeps a kind that is no Integer |

`git diff --shortstat e1d92f1e1 baddd25a9`: 111 files changed, 3212
insertions, 92 deletions (at `ed8c753a4`: 104 files, 2640 and 63). Each replay touches the same files as the commit it
replays, with the same counts, except commit 2 (see its entry).

## Upstream's `--gc=none` (1)

### 1. `047a30699` --gc=none builds a program with no garbage collector

- **Commit**: `047a3069968bf6866aafaf34053bc0ddf38d10fa`, upstream
  `ba5891e0a9d711dd7d1df2bd64d5287aabc0157a` cherry-picked, with its author
  (Yukihiro "Matz" Matsumoto) and its message, including upstream's own
  trailer. Files: `Makefile`, `lib/sp_alloc.c`, `lib/sp_cext_bridge.c`,
  `lib/sp_gc.h`, `lib/sp_sched.c`, `src/analyze.c`, `src/analyze.h`,
  `src/codegen.c`, `src/main.c`, `test/gc_none_alloc.rb`,
  `test/gc_none_alloc.rb.expected`; 64 lines added, 6 deleted.
- **What and why**:
  - **The collector call.** The allocation triggers, `GC.start` and
    `rb_gc_start` call the collector through `sp_gc_collect_fn`, which the
    runtime defines weak as `sp_gc_collect`.
  - **Under `--gc=none`** (or `--no-gc`) the program defines
    `sp_gc_collect_fn` itself, as `NULL`. Nothing then names the collector, and
    with `--gc-sections` its mark, sweep and verifiers leave the link. The first
    trigger that fires lifts both thresholds, so no allocation asks again.
    Memory is allocated and never reclaimed while the process runs.
  - **Users here.** It replaces the process-lifetime arena: the WASM tool's
    `--request-arena` build (`tools/wasm/spinel-wasm`) and
    [decision 0003](decisions/0003-gc-and-arena-build-modes.md)'s build without
    a collector.
- **Switching it on**: `--gc=none` or `--no-gc`; `--gc=on` is the default.
  Without it, the program's C is unchanged.
- **Backport**: one conflict region, `Makefile`'s `test-run` line. The
  resolution keeps this tree's prerequisites and adds `gc-none-test` after
  `gc-threshold-test`; the message ends with one line saying so.
- **Tests**: `make gc-none-test` (in `test-run`) builds
  `test/gc_none_alloc.rb`, which allocates past every trigger and calls
  `GC.start`, checks its output, and checks that `sp_gc_collect` is not in the
  binary.
- **Upstream**: upstream's own commit.

## The selected-root seam (2–5)

`tools/core/spinel-core-build` builds an executable whose selected methods come
from a separately produced native core object, as
[decision 0005](decisions/0005-native-core-executable.md) describes. These
commits make the hosted compiler give each selected top-level method an
external symbol named from a snapshot id, emit no body for it, and write the
mapping from identity to symbol and signature. Nothing changes unless `--core`
is given. The fork's check is `make test-core-seam`
(`scripts/core-seam-check.sh`, 28 cases at commit 5). In this repository the
seam is exercised by `native-core-driver`, `native-core-run` and the other
suites that build through `spinel-core-build`.

### 2. `31ae75c6d` core: give a CLI-selected root a real symbol and no body

- **Commit**: `31ae75c6d2d230e03582d753c824defa81a6870b`, replaying `e97e5607424d701650d1d6f53f7db0aad63d6082`. Files: `Makefile`, `scripts/core-seam-check.sh`, `src/codegen.c`, `src/codegen_fold.c`, `src/codegen_internal.h`, `src/codegen_util.c`, `src/main.c`.
- **What and why**:
  - **Inputs.**
    - `--core <identity>` (repeatable) selects a method.
    - `--core-id=<snapshot>` is half of each symbol.
    - `--core-map=<path>` names where the mapping is written.
  - **What a selected method gets.** External linkage, no forced inlining, a name from the mapping, and a declaration in place of its body. The call site in `src/codegen_fold.c` takes the same name.
  - **Refusals.** `--core` without `--core-id` exits 2, and so does `--core` outside `-c`/`-S`.
  - **The contract.** The commit message calls this an internal linkage contract between the hosted translation unit and the core object. It is not a public ABI.
- **Switching it on**: `--core`. The emitted signature is what inference produced.
- **The message's line numbers** (`codegen.c:2281` and the others) are from the base the patch was first written on; the hunks are elsewhere at this pin.
- **Rebase**:
  - Core naming takes precedence over upstream's new explicit C-name branch.
  - Upstream's debug linkage, inline macros and nullable return types are kept.
  - The declaration-only early return restores upstream's proc-yield state and frees its temporary.
- **Tests**: `make test-core-seam`; `native-core-driver`, `native-core-run`.
- **Replay without the arena** (2026-11-01): 7 conflict regions (`Makefile` 1, `src/codegen.c` 1, `src/codegen_internal.h` 1, `src/codegen_util.c` 1, `src/main.c` 3), each an arena block beside this commit's lines. The diff is the original's with one difference: `src/codegen_util.c` gains 47 lines where the original gained 48, because the original's first added line, a blank line after an arena block, is not added.
- **Upstream**: not proposed.

### 3. `2aef05bea` core: make the selection input fail closed

- **Commit**: `2aef05beaeb5b34eec29dcf873d8bb3632e09746`, replaying `69e678445ceaf0691689d9cfac8b5bd61ad61c0a`. Files: `scripts/core-seam-check.sh`, `src/codegen.c`, `src/codegen_internal.h`, `src/codegen_util.c`.
- **What and why**: the selection is resolved before any emission, whether or not a mapping is written.
  - Each identity must match exactly one method, and a repeated identity is refused.
  - The snapshot id must be `[A-Za-z0-9_]+`, at most 64 characters.
  - `Class.name` and `Class#name` are refused.
  - The symbols are built once, in one table, and checked for collisions with each other and with every other emitted name.
  - The mapping is written to a temporary file with every write checked, then renamed into place.
- **Switching it on**: as commit 2.
- **Rebase**: selection resolution sits right after `analyze_program` at upstream's moved `codegen_program` entry. Upstream's parser notes and scope bookkeeping are kept.
- **Tests**: as commit 2.
- **Replay without the arena** (2026-11-01): applied cleanly.
- **Upstream**: not proposed.

### 4. `d902817cd` core: create the mapping's temporary file exclusively, beside the destination

- **Commit**: `d902817cd5334eff58c8d189d092fec097a9c490`, replaying `4eccb455d2856ec532288cea8f773efb0252f2a3`. Files: `scripts/core-seam-check.sh`, `src/codegen_util.c`.
- **What and why**: the temporary mapping file is created with `fopen(..., "wx")`, under a name unique to the attempt, in the destination's directory. An existing file is never truncated, and concurrent runs do not share a temporary file. Only a file this function created is removed.
- **Switching it on**: runs only with `--core-map`.
- **Rebase**: an additive include collision; `errno.h` and `unistd.h` are added beside upstream's includes.
- **Tests**: as commit 2.
- **Replay without the arena** (2026-11-01): applied cleanly.
- **Upstream**: not proposed.

### 5. `4eb8bb13d` core: never remove the mapping's destination before replacing it

- **Commit**: `4eb8bb13d3fcaa4ecdb7f14dd5e9ffd8644f2f3c`, replaying `5547a03854e30b27f108b558681b91544f5cef55`. Files: `scripts/core-seam-check.sh`, `src/codegen_util.c`.
- **What and why**: removes commit 4's Windows branch, which deleted the destination before renaming. `rename()` replaces the destination in one step, so a failed publication leaves the old mapping in place.
- **Switching it on**: as commit 4.
- **Rebase**: applied cleanly.
- **Tests**: as commit 2.
- **Replay without the arena** (2026-11-01): applied cleanly.
- **Upstream**: not proposed.

## The input ledger (6–8)

`--inputs-out=<path>` writes the files the frontend actually opened, so that a
core build can compare them with the snapshot it was authorised against
(decision 0005). `tools/core/spinel-core-build`, the contract reader
(`tools/contract/build.sh`) and the native tools under `tools/mlir/native` read
it. Without the flag nothing is recorded or written. The suites are
`native-core-ledger` and `native-core-driver`.

### 6. `372f4be76` frontend: record the files actually opened, and write them on request

- **Commit**: `372f4be76c58bd2d8201d0b1a0e999e5a6152d3e`, replaying `96c374f7ea111e5eb25dcf3b420430ef9de93561`. Files: `src/main.c`, `src/spinel_parse.c`.
- **What and why**:
  - **Where it records.** At `read_file` in `src/spinel_parse.c`, the one function every load goes through.
  - **What it records.** Resolved paths, each followed by one NUL byte.
  - **Failures.** A recording failure or an empty ledger makes the write fail, and a failed write removes its partial file.
  - **When it is written.** Before the `-S` and `-c` early returns.
- **Switching it on**: `--inputs-out=<path>`.
- **Rebase**: an additive collision in `src/main.c` with upstream's timing probe. The probe is kept, and the ledger is written before the early returns. Upstream's parser rewrite left the `read_file` open site in place, and it takes the hook unchanged.
- **Tests**: `native-core-ledger`, `native-core-driver`.
- **Replay without the arena** (2026-11-01): 1 conflict region, in `src/main.c`, beside an arena block.
- **Upstream**: not proposed.

### 7. `9408dedb4` frontend: make the ledger opt-in, and publish it without destroying one

- **Commit**: `9408dedb4682ca119104df311a81488637f281f2`, replaying `198d0df82f0b2ac625e8f32013798dd5280f4ca6`. Files: `src/main.c`, `src/spinel_parse.c`.
- **What and why**:
  - Recording is now enabled explicitly, before the parse, so a build without the flag does no recording at all.
  - The ledger is written through an exclusively created temporary file and renamed into place, so a failed run keeps a previous ledger.
  - Both `fflush` and `fclose` are always called.
- **Switching it on**: as commit 6.
- **Rebase**: applied cleanly.
- **Tests**: as commit 6.
- **Replay without the arena** (2026-11-01): applied cleanly.
- **Upstream**: not proposed.

### 8. `e978eeb37` frontend: refuse a ledger for a run that recognised a load it did not satisfy

- **Commit**: `e978eeb37f875370b49d753361bdde17e8a577ad`, replaying `0f58b21466fea4d430c06ce5389e4009aa3cf3d3`. Files: `src/spinel_parse.c`.
- **What and why**: a `require` that resolves to no file leaves no entry, so a ledger alone cannot say that everything the program asks for was analysed. Such loads are now counted, and a ledger is refused for a run that has one, naming the first. Resolution and compilation are unchanged; only the ledger is refused.
- **Switching it on**: as commit 6.
- **Rebase**: applied cleanly.
- **Tests**: as commit 6.
- **Replay without the arena** (2026-11-01): applied cleanly.
- **Upstream**: not proposed.

## External definitions for named methods (9)

### 9. `716b7f553` codegen: SPINEL_EXTERN_METHODS, external definitions for named top-level methods

- **Commit**: `716b7f553bda5bd796d3b940ada4b3610a2c0f28`, replaying `bc51716ea49e21519b5f66ca3f75c57885310100`. Files: `src/codegen.c`.
- **What and why**:
  - **The variable.** It holds a comma-separated list of top-level method names.
  - **Each named method.** It is emitted as an `extern` declaration with a fixed prototype: `sp_int` parameters, and an `sp_int` or `void` return. Its body is skipped, and another translation unit defines it.
  - **Users.** The eBPF tools (`tools/ebpf`) use it, as do the LLVM lane (`tests/llvm`) and the allocation monitor (`tools/gcmon`).
  - **Source and size.** It is spinel-ebpf's Patch 1, with the type spelled `sp_int` where the source said `mrb_int`. It adds 48 lines: two helpers and two early returns. See [Patch 1: SPINEL_EXTERN_METHODS](provenance.md#patch-1-spinel_extern_methods-2026-09-23).
- **Switching it on**: the environment variable `SPINEL_EXTERN_METHODS`. Unset or empty, both hooks return before doing anything, and code generation takes upstream's path.
- **Rebase**: the helpers are inserted without removing upstream's new backtrace and nullable-return helpers. Upstream's IO-reopening checks and proc-yield bookkeeping still run for every ordinary method.
- **Tests**: `ebpf`.
- **Replay without the arena** (2026-11-01): applied cleanly.
- **Upstream**: not proposed.

## The abort entry (10)

### 10. `bc050e4e6` runtime: add sp_abort_uncaught, an uncaught report no frame can catch

- **Commit**: `bc050e4e630cc23bcc5bdc335604202e046951fd`, replaying `3c498405714d84e86c3106581fa7b93cef55280f`. Files: `lib/spinel_rt.h`.
- **What and why**: [Decision 0015](decisions/0015-core-scalar-arithmetic.md) ends the program, as `--exceptions=abort` does, when arithmetic fails in a native core object, because such an object has no rescue frame to raise into.
  - **The new entry.** `sp_abort_uncaught(cls, msg)` runs the `at_exit` hooks, prints what an uncaught raise of `cls` prints and exits with its status. It does not consult armed rescue frames, so `ensure` clauses between do not run.
  - **The shared tail.** The end of `sp_raise_cls`'s uncaught path moves into `sp_exc_end_uncaught`, which both entries call.
  - **Who calls it.** It is declared for `SPINEL_EXT_HOST` too. The native lowering emits calls to it (`tools/mlir/native/lib/Core/Emit.cpp`).
- **Switching it on**: a new function. Nothing calls it unless a program links code that does. The uncaught report of an ordinary raise is the same text, from the same code.
- **Rebase**: written on `e1d92f1e1`, so no rebase. It was cherry-picked without conflict.
- **Tests**: `native-core-arith`, `doom-abort-controls`.
- **Replay without the arena** (2026-11-01): applied cleanly.
- **Upstream**: not proposed.

## Loops without signal polls (11)

### 11. `b14139050` codegen: --no-loop-sig-poll, an opt-in build whose loops do not poll

- **Commit**: `b14139050a2dd0e5e99f47a238fc2fd0f97dccd2`, replaying `6aa5f639508d615890f144e6b2c816f178cd2469`. Files: `src/codegen.c`, `src/codegen_internal.h`, `src/codegen_iter.c`, `src/codegen_stmt.c`, `src/codegen_util.c`, `src/main.c`.
- **What and why**:
  - **Why it exists.** Upstream polls for a pending signal at each loop's back-edge or in its proved condition. The gradient generator (`tools/grad/spinel-gradgen`) needs a differentiated method to reach no allocation and no non-raise abort, and that poll reaches both.
  - **What the flag does.** It turns off the back-edge poll and the condition poll. The method-entry poll on a call cycle is kept.
  - **The marker.** The generated C starts with `#define SP_NO_LOOP_SIG_POLL 1`, so a consumer can tell that a missing poll comes from the flag.
  - **The cost.** With the flag, a signal that arrives during such a loop waits for the next safe point, and a loop that never ends is not interrupted.
- **Switching it on**: `--no-loop-sig-poll`, which the driver passes on as the environment variable `SPINEL_NO_LOOP_SIG_POLL`. Without it, `loop_sig_polls()` equals upstream's `sig_polls()`, and the C is upstream's.
- **Rebase**: written on the abort entry, so no rebase.
- **Tests**: the gradient suites under `tests/grad`. `spinel-gradgen` is the only caller, and it checks that the C it compiles has no loop poll. See [Eighteenth local patch](provenance.md#eighteenth-local-patch-builds-whose-loops-do-not-poll-for-signals).
- **Replay without the arena** (2026-11-01): applied cleanly.
- **Upstream**: not proposed.

## Mutable String FFI borrowing (12)

### 12. `5630a4e28` Add synchronous mutable String FFI borrowing

- **Commit**: `5630a4e28a0f58ab8365151e738494abfe6025e5`, replaying `ad4bb8c4238ddeaa801dc434b84f0b5cfd865af1`.
- **Files**:
  - **Sources and docs:** `docs/FFI.md`, `lib/sp_string.h`, `scripts/ffi-string-borrow-check.sh`, `src/analyze.c`, `src/analyze_desugar.c`, `src/analyze_scope.c`, `src/codegen_call_class.c`, `src/codegen_internal.h` and `src/ffi_spec.c`.
  - **Tests:** 26 refusal inputs under `test/ffi-str-inout-refuse/`, each a `.rb` with its `.reason`, and six `test/ffi_str_inout*.rb` programs with their expected output.
- **What and why**: [Decision 0016](decisions/0016-ffi-mutable-string-borrow.md).
  - **The new spec.** `:str_inout` is an argument-only `ffi_func` spec. For the length of a synchronous call, it lends an original mutable String's own bytes as `char *`.
  - **Before and after the call.** Arguments are prepared in order, and ownership is checked before any address is exposed. Afterwards the String's hash, ASCII and length caches are invalidated.
  - **What is refused.** Routes the producer check cannot prove, frozen data, and the exclusions decision 0016 lists.
  - **`:str`** is unchanged.
  - **The user here.** The DOOM GPU raster lends its screen and zone with it (`examples/doom/lib/doom/render_gpu.rb`).
- **Switching it on**: a program declares `:str_inout`. Programs that do not are compiled as before.
- **Rebase**: written on `e1d92f1e1`'s stack, so no rebase.
- **Tests**: `scripts/ffi-string-borrow-check.sh` in the fork; `raster-string-borrow` here.
- **Replay without the arena** (2026-11-01): applied cleanly.
- **Upstream**: not proposed.

## spinel-mlir's transport (13–16)

spinel-mlir carries its compiler patches as files: M1, M2, M3 and M4, made
against upstream `086d514d`. None of them applied to this pin as it was, so
each is reapplied, or derived as M3′ and M4′, at the places the code it hooks
now lives. Together they write Spinel's facts about one run, the analysed AST,
the inferred types and the code generation evidence, as an MLIR module of the
`spinel_facts` dialect. The contract text is
[`third_party/spinel-mlir/spinel_facts.md`](../third_party/spinel-mlir/spinel_facts.md),
and spinel-mlir's own ledger is
[`third_party/spinel-mlir/SPINEL_MLIR_PATCHES.md`](../third_party/spinel-mlir/SPINEL_MLIR_PATCHES.md).
The native lowering (`tools/mlir/native`) and the bcc tools'
fact capture (`tools/bcc-facts`, `tools/spinel-mlir`) read these modules. Every
flag is opt-in; `git diff 5630a4e28 bc3cd66c2` adds 801 lines in 15 files and
deletes none. See [Patch 2](provenance.md#patch-2-spinel-mlir-m1m3-the-spinel_facts-contract-v2-2026-10-25),
[Patch 3](provenance.md#patch-3-spinel-mlir-m4-the-typing-probe-2026-10-27) and
[Writing Spinel's facts as MLIR](building.md#writing-spinels-facts-as-mlir).

The suites that read the modules are `spinel-mlir`, `bcc-facts`, `core-report`,
`lowering-locations`, `lowering-reopened`, `core-run` and `native-core-run`.

### 13. `468c48b0d` M1: opt-in generic MLIR transport (--emit-mlir=<path>)

- **Commit**: `468c48b0dc3e23a9ffe772f55ac5c7a043776e2b`, replaying `70c9f66508768d67cbf9390285bebd836dd153d6`. Files: `src/codegen.c`, `src/codegen_util.c`, `src/emit_mlir.inc`, `src/emit_mlir_globals.inc`, `src/emit_mlir_snapshot.inc`, `src/main.c`, `src/spinel_parse.c`.
- **What and why**:
  - **The mode.** `--emit-mlir=<path>` writes the facts module, and is a mode of its own. An empty path exits 2, and so does `--emit-mlir` combined with another emit mode.
  - **Output.** Nothing goes to stdout, and no MLIR library is linked.
  - **The unanalysed table.** `src/emit_mlir_snapshot.inc` deep-copies the parsed node table before analysis, only under the flag. M1 instead parsed the text a second time, and this pin no longer has that text form.
  - **`producer_revision`** names `ad4bb8c42` where M1 wrote `086d514d`. The replay leaves it as it was, although this commit's parent is now `5630a4e28`.
  - **The settings.** M1's four settings (`sp_emit_mlir_enabled` and the others) are defined in `src/emit_mlir_globals.inc`, which `codegen_util.c` includes, with their off values; `main.c` declares them and sets them from its flags. So a tool that links Spinel's objects without `main.o`, such as the contract reader or the eBPF tools, links at this commit. M1 defined them in `main.c`.
  - **Folded.** The settings were a separate commit, `376a7727e`, until 2026-11-01. `70c9f6650`, which this commit replays, holds its M1 part, and the message says so. `70c9f6650` replaced `a64056e8f`, and both still exist on the fork; see [Patches 2 and 3 folded](provenance.md#patches-2-and-3-folded-2026-11-01).
  - Additions only: 355 lines.
  - **Known defect of the published fork.** `src/emit_mlir_globals.inc` is not in the Makefile's `SPINEL_HDRS`, so an incremental build after the file changes keeps a stale `codegen_util.o`. Building commit 14 in a directory that had built this commit failed its link on an undefined `sp_analysis_root_spec`. A clean build is correct. The defect is not fixed, so that the pinned tree stays the one that was checked (see provenance).
- **Switching it on**: `--emit-mlir=<path>`.
- **Port**: M1's hook lines are placed where the hooked code now is. The adaptations are the snapshot, the revision and the settings' place.
- **Tests**: the suites above; the contract reader's build (`tools/contract/build.sh`) links without `main.o`.
- **Replay without the arena** (2026-11-01): 1 conflict region, in `src/main.c`, beside an arena block.
- **Upstream**: not proposed.

### 14. `7c4cfb9f4` M2: external analysis-root request (--analysis-root=METHOD:TYPE[,TYPE...])

- **Commit**: `7c4cfb9f46a0cd35faef6b80511d4b32eb4876b1`, replaying `4bcb6d6a250e1df8cf211ebd5e39d4f2009c2805`. Files: `src/analysis_root.h`, `src/analysis_root.inc`, `src/analysis_root_emit.inc`, `src/analyze.c`, `src/emit_mlir.inc`, `src/emit_mlir_globals.inc`, `src/main.c`.
- **What and why**:
  - **The flag.** `--analysis-root=METHOD:TYPE[,TYPE...]` seeds analysis with a top-level method and its argument types. It is valid only with `--emit-mlir`, and can be given up to 16 times.
  - **What it records.** The module records what was requested apart from what was resolved; that is contract version 2.
  - **Who uses it.** The bcc tools' fact capture passes one root per BPF program the source declares (`tools/bcc-facts/emit-facts.rb`).
  - **The setting.** `sp_analysis_root_spec` is defined in `emit_mlir_globals.inc` and declared in `main.c`, for the reason entry 13 gives; `analyze.c` refers to it.
  - **Folded.** `4bcb6d6a2`, which this commit replays, holds the M2 part of the former `376a7727e`, and the message says so. `4bcb6d6a2` replaced `9ac32c35f`; `git diff 9ac32c35f 4bcb6d6a2` is `git diff a319eaf0d 376a7727e`.
  - **Diff counts**: 316 lines added and 5 deleted. The five deleted lines are M1's comment in `emit_mlir_globals.inc`, which now names M1 and M2. No line of `ad4bb8c42` is deleted, which is why the cumulative diff above deletes none.
- **Switching it on**: `--analysis-root`, with `--emit-mlir`.
- **Port**: M2's files are unchanged, except `producer_revision` in `analysis_root_emit.inc`. The hooks are M2's lines at their moved places.
- **Tests**: `spinel-mlir`, `bcc-facts`.
- **Replay without the arena** (2026-11-01): applied cleanly.
- **Upstream**: not proposed.

### 15. `bc3cd66c2` M3': original-file positions for this pin, derived from M3

- **Commit**: `bc3cd66c218f46380bfe336d68c54cab24f2c5f7`, replaying `9c20d87a02af9688415366e66cb8255a096b26bd`, which is `a319eaf0d` cherry-picked with the former `376a7727e`'s tree. Files: `src/emit_mlir.inc`, `src/source_map_pin.h`, `src/source_map_pin.inc`, `src/source_map_pin_decl.inc`, `src/source_map_pin_emit.inc`, `src/spinel_parse.c`.
- **What and why**:
  - **Why M3 is not needed as it was.** M3 kept a second line map, because Spinel's own map counted each inserted `require` as a line. At this pin upstream marks an inserted require with `SPINEL_INSERT`, which counts no line, so M3′ corrects no position.
  - **The checks it keeps.**
    - Each buffer line a node starts or ends on is compared byte for byte with the file and line the facts name. A mismatch is refused with `MLIR M3 unrecoverable span … reason=content`, exit 1.
    - A node whose end lies in another file than its start gets no position.
  - **The optional `spinel_facts.splice` op is not emitted.** At this pin, eight of the inserted requires' callers are builtins whose origin is not one of the contract's values.
  - **Known limitation.** A span whose buffer lines no longer match the original file after Spinel has rewritten the buffer (the compile-time expansion of a class-body macro, the `native_*` declarations) cannot be recovered. The run is refused loudly with `MLIR M3 unrecoverable span`, exit 1. At this pin, 21 of upstream's test programs are refused this way.
  - Additions only: 135 lines, in new files named `source_map_pin*`.
- **Switching it on**: active only under `--emit-mlir`.
- **Port**: derived from M3, not applied.
- **Tests**: `spinel-mlir`, `lowering-locations`.
- **Replay without the arena** (2026-11-01): applied cleanly.
- **Upstream**: not proposed.

### 16. `ed8c753a4` M4': spinel-mlir's typing probe (--emit-typing-probe), for this pin

- **Commit**: `ed8c753a4ca0b82774d7a10ce062c00bbf5f579d`, replaying `67fba6d346074ca7ab40f0a5a7475cfa8eb39e39`, which is `eee3df25b` cherry-picked with the same tree. Its tree, `602ebec941f2f59e9acc71be0b217b7de96e2db0`, is the tree of `ae3a9fec7`, the arena removed on the previous pin (see provenance). Files: `src/analysis_root_emit.inc`, `src/emit_mlir.inc`, `src/emit_mlir_globals.inc`, `src/main.c`, `src/source_map_pin.h`, `src/source_map_pin.inc`, `src/spinel_parse.c`, `src/typing_probe.h`, `src/typing_probe_emit.inc`, `src/typing_probe_main.inc`, `src/typing_probe_sha.inc`.
- **What and why**:
  - **The probe.** `--emit-typing-probe` is accepted only with `--emit-mlir` and at least one `--analysis-root`. Spinel forks before parsing. The child analyses the program without the roots and sends its types back, and the parent analyses with them.
  - **What the module gains.** The dictionary `spinel_facts.typing_probe`, version 1:
    - `complete` and `producer_patch`;
    - the source file and its sha256;
    - the requested roots;
    - the types before and after;
    - the child's stderr.
  - **Who needs it.** spinel-mlir's consumer, for a bcc tool that embeds a kernel struct.
  - Its diff adds 147 lines and changes one.
- **Switching it on**: `--emit-typing-probe`. Without it there is no fork and no extra analysis.
- **Port**:
  - **Kept as they are:** `typing_probe.h`, `typing_probe_emit.inc`, `typing_probe_sha.inc` and the `analysis_root_emit.inc` hunk.
  - **Moved:** `main.c`'s four hooks, and `emit_mlir.inc`'s include.
  - **New for this pin:** `sp_m3_top_file`, which M4 reads and M3′ lacked. It is set where `sp_build_line_map` interns the top-level file, and that is the one changed line of `src/spinel_parse.c`.
  - **The probe's seven settings** are defined in `emit_mlir_globals.inc`, for the reason entry 13 gives.
- **Tests**: `bcc-facts`, `spinel-mlir`; spinel-mlir's producer checks (`tools/spinel-mlir/tests/producer/typing-probe-*.rb`).
- **Replay without the arena** (2026-11-01): applied cleanly.
- **Upstream**: not proposed.

## The collector's event record (17–18)

### 17. `8e1ac9e2c` runtime: SP_GC_EVENTS, an opt-in record of every slab slot's life

- **Commit**: `8e1ac9e2c7f8c25f279ed0abd5a593b7f6ad6c6a`, on `ed8c753a4`, the fork's `gc-events`. Files: `.gitignore`, `Makefile`, `lib/sp_gc.c`, `lib/sp_slab.c` (214 lines added, 20 removed).
- **What and why**: decision [0036](decisions/0036-gc-event-record.md). The runtime's verifier sites that note slab slots also feed a recorder; a collection records its root stack; a census at exit names the slots still allocated.
- **Switching it on**: build `make events-runtime` (`lib/libspinel_events_rt.a`, `-DSP_GC_EVENTS`), then run with `SPINEL_GC_EVENTS=FILE`. The regular archive is not rebuilt, and without the switch `SP_SLAB_NOTING` is `sp_slab_verify_on` itself.
- **Tests**: `gcviz` (`tests/gcviz/run.sh`).
- **Upstream**: not proposed.

### 18. `edb7761b7` runtime: SP_GC_EVENTS records the stack behind each allocation and collection

- **Commit**: `edb7761b75461c485d4df64cacf197ab3f2f478b`, on `8e1ac9e2c`, the fork's `gc-events`. Files: `lib/sp_gc.c`, `lib/sp_slab.c` (29 lines added, 2 removed).
- **What and why**: decision [0036](decisions/0036-gc-event-record.md). Each recorded allocation and each collection's start is followed by the return addresses of the stack behind it (what 400 and 401), read with `_Unwind_Backtrace` from the unwind tables. `tools/gcviz/gcviz-events.rb` resolves them with `llvm-symbolizer`; Spinel's `#line` directives make a compiled Ruby frame resolve to its `.rb` line, so the replay can show which line allocated each slot and which allocation started each collection.
- **Switching it on**: as entry 17. Nothing is compiled without `SP_GC_EVENTS`.
- **Tests**: `gcviz` (the line checks and the `no-site` control).
- **Upstream**: not proposed.

### 19. `c23d82a7c` runtime: SP_GC_EVENTS records the blocks malloc'd outside the slab

- **Commit**: `c23d82a7c5d27a04de407a086fa8068b26f78aee`, on `edb7761b7`, the fork's `gc-events`. Files: `Makefile`, `lib/sp_alloc.c`, `lib/sp_alloc.h`, `lib/sp_gc.c`, `lib/sp_gc.h`, `lib/sp_slab.c`, `lib/spinel_rt.h` (94 lines added, 14 removed).
- **What and why**: decision [0036](decisions/0036-gc-event-record.md). With the slab off (`SPINEL_GC_SLAB=0`), past `SP_SLAB_MAX` or when the slab is full, objects, heap strings and payloads are malloc'd and the collector keeps them on lists. The record now follows them too: allocation (what 11/12/13, with its stack), a header taken back from a per-class or PolyArray pool (14), explicit free (16), sweep from a list (17) and survival of a young list sweep (32: promoted, or kept young by `SPINEL_GC_AGE=1`). The owner asked (2026-11-12) to see the slab on and off side by side. A collection that would start helper threads stops the record with a message instead of writing to it unlocked.
- **Switching it on**: as entry 17, except that the pools sit in headers compiled into the program, so `make events-runtime` now compiles every runtime member with `-DSP_GC_EVENTS` and `tools/gcviz/gcviz-build` compiles the program with it. Without the switch the default build reads the same tokens as before, apart from three verifier notes for malloc'd blocks, which the verifier ignores (`sp_slab_note` returns for a block the slab does not own).
- **Tests**: `gcviz` (the slab-off and aging runs replay cleanly; their allocations resolve to the same lines).

### 20. `baddd25a9` A local a while multiplies keeps a kind that is no Integer

- **Commit**: `baddd25a966d9cd5c2f62a3e42a717285cb3d9fe`, on `c23d82a7c`, the fork's `pin/while-float-bd53f593`: `cherry-pick -x` of upstream `bd53f593856ab739ceb82795f0fdf25d9f850cf8` (alfonso, 2026-11-06). Files: `Makefile`, `src/analyze_pass.c`, `test/while_mul_keeps_local_kind.rb`, `test/while_mul_keeps_local_kind.rb.expected` (243 lines added, 1 removed, as upstream's).
- **What and why**: before the round types a local's writes, `analyze_pass.c` seeds a local that a `while` loop grows by `*` as a Bignum, so `y = y * 0.5` or `y *= 0.5` made a Float local untyped (`poly`), which the freestanding route refuses. The fix asks first whether one of the local's writes gives a kind that is not Integer; if so, no Bignum seed is placed. An Integer local still grows past the word. Taken now, ahead of an upstream synchronisation, by the owner's decision of 2026-11-14 ([provenance](provenance.md#upstreams-float-in-while-fix-backported-2026-11-14)).
- **Switching it on**: always on.
- **Tests**: upstream's `test/while_mul_keeps_local_kind.rb` under `make infer-test`; here, E084's `n4_loop_mul`, now accepted (`freestanding`).
- **Upstream**: upstream's own commit.

## New at the 2026-11-14 synchronisation (21–23)

### 21. `e72f8a112` codegen: count only the written ARGV slots in sp_argv.len

- **Commit**: `e72f8a112930345278eb63640fea281f882d14d6`, on `ffbc653e8`; it replays `3ac5c2853` (the fork's `argv-fill-order`). Files: `src/codegen.c` (5 lines added, 2 removed).
- **What and why**: the generated `main` copies each ARGV string, and a copy can start a collection, which marks `sp_argv.data[0 .. len)`. Upstream set `sp_argv.len = argc - 1` before the fill, so a collection during the copy marked slots not yet written. The fill now sets `len` after each slot it writes. Upstream since wraps each slot in `sp_str_retained`; the replay keeps that and moves only `len` (the message's sync paragraph).
- **Switching it on**: always on. The generated C differs from upstream's only on the ARGV setup line.
- **Tests**: `spinel-fork-argv-fill` (`tests/spinel-fork/argv-fill.sh`): ARGV copied under `SPINEL_GC_STRESS=1` and `MALLOC_PERTURB_` answers, and upstream's own fill line, planted as a control, crashes.
- **Upstream**: not proposed.

### 22. `f25a0222b` analyze: the prune of unnamed methods keeps the roots named from outside

- **Commit**: `f25a0222b31cb40f6a06d1640540b412f69580de`, on `e72f8a112`. Files: `Makefile`, `scripts/prune-roots-check.sh`, `src/analyze_desugar.c` (143 lines added).
- **What and why**: upstream `7bc3fe018` blanks a top-level method that no node of the program names (`prune_unnamed_methods`). A method named only from outside the program text is such a method: an `--analysis-root` request, a `SPINEL_EXTERN_METHODS` entry, a `--core` identity. The prune blanked them, and those switches then refused the request. Their names now go into the prune's set of named methods (`Class#m` and `Class.m` add `m` too); the rest of the prune is upstream's. This repository's contract reader runs the analysis in process and adds a CORE kernel's roots to the same list with `spinel-typedump --keep-method=NAME`.
- **Switching it on**: always on; it changes only which methods the prune keeps, and only when one of the three switches names a method.
- **Tests**: `make test-prune-roots` (`scripts/prune-roots-check.sh`, 5 cases; with the change reverted, the analysis-root and `--core` cases fail); here, `core-upstream-fields` (a reader that drops `--keep-method` leaves the entry pruned and refused).
- **Upstream**: not proposed.

### 23. `b1b0702da` codegen: the ARGV fill starts from sp_argv.len = 0

- **Commit**: `b1b0702da9e3c916d72b53850b1b4905e611e4a7`, on `f25a0222b`. Files: `Makefile`, `scripts/argv-rerun-check.sh`, `src/codegen.c` (81 lines added, 2 removed).
- **What and why**: entry 21 did not reset `len` before the fill. A `main` run again in the same process (a host that calls the program's `main` once per request) kept the previous run's count, so the second run's first copy marked that many slots of its new, unwritten block. The fill now starts from `sp_argv.len = 0`.
- **Switching it on**: always on; the ARGV setup line only.
- **Tests**: `make test-argv-rerun` (`scripts/argv-rerun-check.sh`: `main` twice in one process under GC stress and perturbed malloc; its control, without the reset, fails 3 of 3 runs); here, `spinel-fork-argv-fill`, whose needle is this commit's line.
- **Upstream**: not proposed.

### 24. `dedf05317` runtime: puts(*a) writes a String element by its byte length

- **Commit**: `dedf05317bef238db1cb21bfeba847847c9fc736`, on `b1b0702da`. Files: `lib/spinel_rt.h` (3 lines added, 1 removed), `test/puts_splat_binary_string.rb` and its `.expected`.
- **What and why**: upstream `f8ff01939` makes a String local a mutable handle, and a StrArray element read through `sp_poly_arr_get` now arrives as that handle (cls `SP_BUILTIN_STRBUF`), not as `SP_TAG_STR`. `sp_puts_elems` sent only `SP_TAG_STR` to the sized writer; the handle went to `fputs`, which stops at the first NUL, so `puts(*["P" + 0.chr + "Q"])` printed `P`. The element is now unwrapped with `sp_rbval_str` first, as `sp_poly_print` already does.
- **Switching it on**: always on.
- **Tests**: `test/puts_splat_binary_string.rb` (ledger case B14); with the fix reverted it fails at line 3; it passes with it, also under `SPINEL_GC_STRESS=1`.
- **Upstream**: suspected upstream defect, not reported.

### 25. `4e0a59bd9` runtime: a String handle stored into a StrArray does not widen it

- **Commit**: `4e0a59bd999e614bd8b2ece72ec2b8d0cbbc5522`, on `dedf05317`. Files: `lib/spinel_rt.h` (3 lines added, 1 removed), `test/str_array_in_hash_store_aliases.rb` and its `.expected`.
- **What and why**: with String locals as handles, `pieces[1] = body` passes `sp_poly_arr_widen_and_set` the box `SP_STR_BOX(lv_body)` (cls `SP_BUILTIN_STRBUF`), where `baddd25a9` passed `sp_box_str(lv_body)`. The widen test read any tag but `SP_TAG_STR` as a non-String for a StrArray, so it copied the Array into a new PolyArray; the local took the copy and a Hash holding the same Array kept the old one without the store. A handle now counts as a String there (as `sp_poly_arr_misfit` already counts it), and `sp_StrArray_set_e` stores it in place. Seen as `tests/doom-core/net-view.sh`: the viewer's frame assembly (`net_view.rb` `Stream#piece`) lost every piece.
- **Switching it on**: always on.
- **Tests**: `test/str_array_in_hash_store_aliases.rb`; with the fix reverted `h[0]` prints `0,0,0` where it must print `0,2,0`; it passes with it, also under `SPINEL_GC_STRESS=1`. Not changed: a `nil` stored into a StrArray held elsewhere still widens into a copy the other holder does not see (`baddd25a9` does the same).
- **Upstream**: suspected upstream defect, not reported.

## Reproduction

```sh
git -C vendor/spinel log --reverse --oneline f8ff01939..4e0a59bd9
git -C vendor/spinel show <commit>
```
