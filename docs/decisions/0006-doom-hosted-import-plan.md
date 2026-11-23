# Hosted CPU DOOM Import Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` task by task. Work sequentially; delegate only if the user requests it. Report completed changes and actual results separately from future work.

**Goal:** Build and play the existing Ruby CPU DOOM example on Mac using the pinned hosted compiler, with reproducible independent checks on Mac and IWAD-independent checks on Debian.

**Architecture:** Ruby game logic and direct CPU rendering compile through Spinel's normal C path. SDL2 is isolated behind the existing C shim. A minimal no-GPU adapter satisfies existing startup bindings; it supplies no GPU capability. No compiler/backend or memory-contract change is planned.

**Tech stack:** Pinned Spinel, LLVM/Clang 23.1.1, SDL2, pkg-config, Bash, CRuby, and a pinned headless doomgeneric oracle.

**Spec:** [0006-doom-hosted-import.md](0006-doom-hosted-import.md), accepted for implementation on 2026-09-11.

All commands below that name new `examples/doom` or `tests/doom` scripts describe the planned interface; those scripts do not yet exist. These are acceptance commands, not a claim that an import has already been performed.

## File layout and import rules

| Source at the recorded predecessor revision | Destination / responsibility |
|---|---|
| `doom/lib/doom/*.rb` required by CPU entry and checks | `examples/doom/lib/doom/`: game logic, tables, rendering, input, SDL interface and minimal startup adapters |
| `doom/bin/doom.rb` | `examples/doom/bin/doom.rb`: interactive entry |
| `doom/bin/{sim_demo,record_demo}.rb` and required dump/probe entries | `tests/doom/programs/`: headless oracles and probes; adjust only relative load paths |
| `doom/tools/sp_sdl_shim.c` | `examples/doom/native/sp_sdl_shim.c` |
| `tools/raster/sp_raster_gpu_stub.c` | `examples/doom/native/sp_raster_gpu_stub.c`: no-device ABI adapter only |
| `doom/test/*.rb`, corresponding `.expected`, `script*.txt` | `tests/doom/fixtures/`, preserving expected content and input scripts |
| Required `doom/tools/gates/*.rb`, comparison helpers | `tests/doom/support/`: comparisons shared by actual runners |
| `doom/reference/*.patch` and required headless patch under `docs/researches/r007_probes/reference/` | `tests/doom/reference/patches/`: narrowly selected build inputs, not the research directory |
| `docs/researches/r007_probes/reference/results/demo1_hashes.tsv` (463,676 bytes) | `tests/doom/fixtures/reference/demo1_hashes.tsv`: this file only, with source hash and attribution; no research results directory |
| Required table generators | `examples/doom/tools/`: preserve deterministic generation and explicit oracle source revision |
| Existing build/fetch/test recipes | Adapt as `examples/doom/build.sh`, `examples/doom/fetch-wad.sh`, `tests/doom/{run,headless,interactive}.sh` and `tests/doom/reference/build.sh` |
| Maintained documentation | `examples/doom/README.md`, `docs/doom.md`, `docs/provenance.md`, short README/roadmap links |

The CPU manifest must include `jobs.rb` and `executor.rb` required by `render.rb`, and `hires.rb` required by both the interactive and simulation entries. `render_gpu.rb` belongs to the interactive dependency closure only. The recorded SHA-256 of `demo1_hashes.tsv` is `0b98fc30ee21a552e31de409b03ba7afae54581967c9b8ebba281247ce5402ac`.

Do not bulk-copy `doom/` or the predecessor's tools/docs trees. Enumerate the transitive imports of each selected entry. Keep original-to-local path and content-hash records in provenance. Adapt maintained comments/docs to English; preserve attribution text even where it is in another language. Do not rewrite game algorithms as part of this import.

## Task 1: Inventory and pinned compatibility checkpoint

- [ ] Inspect clean status; create `feat/doom-hosted` in an isolated Extended worktree after plan approval.
- [ ] Read the source revision from Git objects, not untracked files. Record both compiler pins from the spec and preserve all source worktree changes.
- [ ] Enumerate `require_relative` and FFI dependencies for the interactive entry, `sim_demo`, `record_demo` and selected unit tests. Include the always-constructed GPU adapter and generated tables; exclude independent GPU/demo/benchmark programs.
- [ ] Inventory licences/notices and table/fixture provenance. Separate code, reference-engine code, and IWAD data; record each unresolved item without assigning a new licence.
- [ ] Build a compiler-compatibility ledger for all 11 bugfix batches listed below. Locate each batch's minimal reproducers in its source experiment record or commit; execute them on Extended's pin with explicit compiler flags and expected output/status. A batch can contain multiple defects: enumerate them, rather than assuming one small example covers the batch. Preserve the source revision and reproducer path, but import only necessary executable fixtures, not experiment logs.
- [ ] For each reproducer record source-fork expected behavior, current-pin behavior, and verdict: resolved upstream, reproduced defect, demonstrably irrelevant to this DOOM path, or not yet tested. Do not infer behavior from Git ancestry, and do not count untested as compatible.
- [ ] In disposable scratch space, compile the IWAD-independent CPU probes with the current Extended compiler. Do not change the predecessor or use its compiler as the accepted target.

  Probe compiler invocation (after assembling the selected files in scratch):

  ```sh
  "$EXTENDED/vendor/spinel/bin/spinel" "$PROBE_SOURCE" \
    --cc="$LLVM_PREFIX/bin/clang" -o "$PROBE_OUTPUT"
  "$PROBE_OUTPUT" "$SCRATCH_INPUT_DIR"
  ```

- [ ] Compare each probe with CRuby and its existing expectation; capture exit status before comparison.
- [ ] **Go/no-go before Task 2:** present the file manifest, the five DOOM probe results and the 11-batch compatibility ledger. Untested relevant behavior, unexplained differences or a reproducible required compiler defect keep this checkpoint open. Successful probes permit the scoped import to proceed only with the GPL inclusion decision recorded; they do not pre-approve a compiler patch. If a pin/compiler defect blocks progress, reduce it and propose the minimum fix separately. Do not switch back to the predecessor pin to make the import pass.

### Compiler batches to account for

| Batch | Fork commit | Primary source experiments |
|---|---|---|
| 1 | `99a5fc49` | E019/E020/E021, integrated E024: GC soundness |
| 2 | `61ffe24e` | E023/E028/E029/E032: loop-source rooting |
| 3 | `8154ec0c` | E043: folding and scope merge |
| 4 | `c02ca2cf` | E045/E046: builtin exception poly dispatch |
| 5 | `7d8a6408` | E045/E048: builtin pre-arm unboxing |
| 6 | `da2d009d` | E049/E050/E065: poly call result widening |
| 7 | `8648d478` | E059: widened String writes |
| 8 | `cec1ec4d` | E086: String output length |
| 9 | `883957dd`, `bd2d276a` | E096/E098: included ivars and return rederivation |
| 10 | `f8512260` | E144: empty FloatArray nil sentinel |
| 11 | `ecbd0f2a` | E146: nil float rendering |

These are 11 batches, not 11 individual fixes, and they were not all discovered in DOOM. Record actual relevance and execution evidence, not that attribution.

## Task 2: Import the headless game and independent checks

- [ ] Record owner acceptance of GPL-derived files in `examples/doom/` and `tests/doom/`, with the required licence/notice files. Do not start the import without this decision.
- [ ] Import only Task 1's manifest. Bring the required test programs and fixtures with the library, so the first code commit has executable validation.
- [ ] Adapt test entry paths and the runner to build through pinned `vendor/spinel`; use `--cc` for every generated program and the same compiler for C helpers.
- [ ] Expose `LLVM_PREFIX`, `RUBY`, `BUILD_DIR`, `WORK_DIR`, and `WAD` as explicit overrides. Defaults resolve within this checkout or fresh owned temporary directories; no developer-home paths or sibling dependencies.
- [ ] Make `tests/doom/run.sh` require compiler success and expected process status, retain the source runner's combined stdout/stderr `.expected` bytes, and compare both compiled and CRuby combined output against them. Also capture stderr separately and require it to be empty for the five normal fixtures. Use an additional run for the separate-stream check if necessary; do not assume a reconstructed concatenation preserves stream order. A missing expectation is an error, not an update request.
- [ ] Exercise a failed compiler, matching-output processes that exit nonzero, and a deliberately wrong expected value. Each must fail the runner. Never regenerate golden outputs automatically during acceptance.

```sh
LLVM_PREFIX=/path/to/llvm-23.1.1 RUBY=ruby tests/doom/run.sh
```

Expected: every imported IWAD-independent test passes with explicit counts and exit 0. Empty test discovery fails. Save the first failure log if compatibility is not established, and keep this task incomplete.

## Task 3: Pin the independent oracle and replay evidence

- [ ] Adapt the reference builder to fetch the exact doomgeneric SHA in the spec into an owned build directory, apply only the required patches, and check every command's status. No reset/clean in a user-supplied source checkout.
- [ ] Preserve the R007 patch bytes and its legacy FNV offset basis `1469598103934665603`. Preserve `demo1_hashes.tsv` bytes; document the known nonstandard constant, identify the legacy column used by the golden gate, and do not change the constant or regenerate this golden during import.
- [ ] Run the C oracle on Mac only in this slice. Its CommonCrypto include and Mac-specific Makefile prevent claiming Debian portability. Do not add an unreviewed hash implementation as incidental portability work.
- [ ] Remove references to predecessor research/experiment directories. Import only required patches and small golden fixtures, with hashes and provenance. Keep downloaded sources and generated logs outside tracked source.
- [ ] Implement explicit WAD acquisition/verification. Verify existing files too; download through an owned temporary file and publish only after length and SHA-256 match. An absent WAD reports a prerequisite failure; normal build does not fetch it silently.
- [ ] Reuse comparisons for random-call sequence, player/thinker state and full frame sequence. Validate expected sequence length, key coverage, uniqueness and ordering before comparing values.
- [ ] Reproduce each inherited reference discrepancy on Mac with the selected oracle toolchain. Preserve concrete expected differences and provenance; a changed or new discrepancy requires investigation, not a larger allowance. Do not assume the old C oracle's undefined behavior is stable across toolchains.
- [ ] Prove comparison failures with empty output, a deleted frame, a duplicated frame, a changed game-state row and a changed frame outside a recorded discrepancy. Assert failure reasons so a missing tool cannot masquerade as a successful negative control.

```sh
examples/doom/fetch-wad.sh build/doom-assets
WAD="$PWD/build/doom-assets/doom1.wad" tests/doom/headless.sh
```

Expected: DEMO1, DEMO2 and DEMO3 complete; game-state comparisons match and frame results match the explicitly recorded baseline. Keep counts and discrepancies per demo and host. The source runner's `l6.rb` only compares rows present in the implementation output, so it must not be imported as sufficient coverage by itself.

## Task 4: Build and exercise the Mac SDL application

- [ ] Adapt the CPU build to use SDL2 discovery through pkg-config or explicit flags; fail with the missing dependency named. Avoid hardcoded Homebrew/library locations.
- [ ] Link the SDL shim and minimal no-device raster stub. Do not require IREE, GPU kernels or MLIR. Update the stub's diagnostic so it does not prescribe a nonexistent Extended GPU build recipe.
- [ ] Compile the pinned hosted program with `--cc` and publish a complete executable from staging in the output directory. Do not trust stale shim objects across source/compiler changes.
- [ ] Use the existing scripted-input recording/replay checks to compare SDL and headless frames. Keep stage exit statuses and missing output checks explicit.
- [ ] On the Mac desktop, open the real SDL window and check movement, turning, firing, door interaction and clean exit. Record the actual observation; screenshots/headless success alone do not prove input handling.
- [ ] Distinguish unavailable display (SKIP) from a broken build/run (FAIL). Overall playable-Mac acceptance remains incomplete until the real-window check passes.

```sh
LLVM_PREFIX=/path/to/llvm-23.1.1 examples/doom/build.sh
build/doom/doom -iwad build/doom-assets/doom1.wad -warp 1 1 -skill 2 -scale 3
WAD="$PWD/build/doom-assets/doom1.wad" tests/doom/interactive.sh
```

Expected: CPU rendering in an SDL window, scripted replay matching the headless result, and verified controls. No new audio/menu/level-transition features or performance target is part of this task.

## Task 5: Reproduce, document and present integration

- [ ] Build and run the documented commands from a clean Extended checkout using only pinned dependencies and explicit asset acquisition.
- [ ] Repeat the five IWAD-independent tests on Debian x86_64. Full C-oracle replay is Mac-only in this import because its reference harness uses CommonCrypto; record Debian reference replay and GUI as unverified, not successful skips.  A portable oracle is separate follow-up work.
- [ ] Run existing eligibility and native driver checks on the unchanged compiler to confirm packaging did not disturb core. A DOOM failure is not a reason to weaken those checks.
- [ ] Write `docs/doom.md` and the example README with **what now works**, commands, controls, supported IWAD, required SDL/toolchain, measured results and inherited missing features. Link provenance and distinguish historical measurements from new ones.
- [ ] Verify local documentation links, whitespace, original-to-local manifest, notice preservation, and absence of predecessor paths, generated binaries, WAD files and experiment archives.
- [ ] Present the exact commit and test evidence for integration. Do not merge/push main or move a pin without authorization for that concrete scope.

## Review boundaries and stopping conditions

Routine path/build adaptations within the approved CPU import continue without repeated approval. A compiler pin change, Ruby semantic workaround, new memory contract, GPU/WASM expansion or unexplained oracle mismatch is a distinct checkpoint. Report the actual blocker and continue independent agreed work.

## Agent assignment

The owner assigned implementation to the Debian side on 2026-09-11, replacing this plan's original "no agent assignment is made" clause.

- **Debian (implementation).** Tasks 1, 2 and 5's Debian half: the compiler-compatibility ledger, the IWAD-independent probes and fixtures, the import itself, the runners, and the Debian reproduction record.
- **macOS (review and validation).** Review of the Debian work, the Mac arm64 C reference oracle, SDL real-window operation, and Mac non-regression. Tasks 3 and 4 are Mac-owned.

Shared compiler builds must not run concurrently in the same tree; each side builds in its own checkout.

A compiler fix or pin move is **not** pre-approved by this assignment. If one is needed, reproduce it and bring the minimum diff as its own proposal. Do not integrate to `main`, force push, or delete branches.
