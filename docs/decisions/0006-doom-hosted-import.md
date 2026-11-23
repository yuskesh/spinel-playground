# 0006: Import the CPU DOOM application on the hosted path

- Date: 2026-09-11
- Status: Accepted for implementation (2026-09-11); Task 1 compatibility checkpoint remains mandatory
- Scope: A native, playable CPU-rendered DOOM example on macOS arm64, with IWAD-independent compatibility checks on Debian x86_64.

## Goal

Build the existing Ruby DOOM application using Extended's pinned hosted Spinel compiler. A user can supply the supported IWAD, open an SDL2 window, move, turn, shoot and operate doors. Deterministic demo playback supplies the regression evidence. This is an application import, not a graphics backend API.

## Baselines inspected

- Extended: `0655b4ef19b80ac8005499c7778d07987c9a293d`.
- Extended compiler pin: `cad0ad148af00b98a3de8a384c18a3cabe15bc1a`.
- Source repository: `spinel-llvm`, `f8ad13c6d9dc990b116ba1c842c7881232f29585`.
- Source repository's compiler pin: `ecbd0f2a7cd134d5affc2bd705f0f0e83aa82101`.
- Independent C oracle named by the source recipe: `ozkl/doomgeneric`, `dcb7a8dbc7a16ce3dda29382ac9aae9d77d21284`, plus the recorded headless/dump patches.

The predecessor fork carries 11 named bugfix batches among its 26 commits since `4241e88a`; the Extended pin has 964 commits since that ancestor. These counts describe history, not behavior: a newer upstream may implement a fix without containing the old fork commit. The five existing IWAD-independent DOOM tests do not establish coverage of all these compiler defects. Task 1 therefore records a reproducer/result for each batch before a go/no-go decision.

The pins differ; source inspection does not establish compatibility. No DOOM build or execution was performed while writing this proposal. Predecessor demo, performance and allocation figures remain historical evidence only.

## Approaches

1. **Import the existing CPU application on the hosted path (recommended).** Reuse game logic, direct software renderer, SDL2 interface and independent checks. This isolates migration defects from memory-tier and backend changes.
2. Import only a headless renderer. Smaller, but does not deliver the playable application; use it as the first validation stage within approach 1.
3. Port directly to core, arena or GPU execution. Requires new contracts and substantially more compiler/backend work; defer it.

## Proposed boundary

Use ordinary Spinel C generation and the default collected runtime. Pass the selected Clang explicitly to both the hosted compiler and C shim compilation. DOOM requires no MLIR build, `freestanding_def`, core selection or arena flag. LLVM 23.1.1 Clang remains the selected C toolchain on both test hosts.

Place the application at `examples/doom/`, executable checks and required fixtures at `tests/doom/`, and reproduction documentation at `docs/doom.md`. Keep Ruby game semantics, fixed-point arithmetic, buffer representation, random sequence and tick ordering unchanged. Use the current Extended pin first. A necessary compiler patch/pin change must return as a concrete separate proposal.

The predecessor's CPU build still loads `render_gpu.rb` and links `tools/raster/sp_raster_gpu_stub.c`; startup constructs the adapter even without `-gpu`. Retain the minimal no-device compatibility adapter and its required Ruby files initially, with an accurate unavailable-backend diagnostic. The CPU transitive set includes `jobs.rb` and `executor.rb` through `render.rb`, and `hires.rb` through both `doom.rb` and `sim_demo.rb`.

Do not import IREE, Metal kernels, GPU build recipes, or claim GPU support. Preserve the existing explicit no-device behavior; do not silently report GPU execution. Retain required generated Ruby tables as source artifacts with their origin and reproduction recipe. Game assets, executables, caches and experiment archives are not imported. A pinned reference checkout and its test-only patches are allowed; no build or test may require the predecessor checkout.

## Assets and attribution

The owner accepted this **GPL-derived DOOM import** on 2026-09-11. The source headers of `tables.rb` and `info.rb` explicitly identify id Software's GPL-2.0-or-later sources; game logic is translated by function and the oracle patches modify the GPL reference engine. Task 2 may start only after the owner accepts including these derived files under `examples/doom/` and `tests/doom/`, with applicable notices and licence text. The owner's Go includes that choice. This does not assign a licence to all of Extended.

Inventory origin and notices for the Ruby translation, generated tables, C shim/stub, oracle patches and test fixtures before copying. Preserve required third-party notices. The predecessor lacks a project-wide licence file; do not infer a licence for translated DOOM code or generated tables from the Spinel compiler's MIT licence. Record unresolved attribution questions separately from technical compatibility, and do not claim redistribution clearance.

Do not commit IWAD files. Accept a user-supplied path and provide a separately invoked acquisition recipe with verified digest and length. The source recipe's shareware fixture is 4,196,020 bytes, SHA-256 `1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771`. Check acquisition sources and applicable notices during implementation; this proposal does not establish that the old download URLs still work.

## Acceptance

- A clean checkout builds the CPU example with the pinned compiler, Clang and SDL2, without MLIR/IREE or a predecessor checkout.
- IWAD-independent tests agree with CRuby and their checked-in combined-stream expectations. Preserve those original bytes; separately assert normal exit and empty stderr for these fixtures. Do not reinterpret combined expectations as stdout-only or regenerate them automatically.
- On Mac, DEMO1/2/3 game-state and frame sequences are compared with the pinned C oracle. Compare complete expected key sets and counts, not just rows that happen to exist. Missing, empty, duplicated or truncated output fails.
- Preserve the predecessor's documented reference discrepancies as explicitly reviewed per-case evidence, not permission to ignore arbitrary pixels or all failures in an allowed tick. Any unexplained new difference blocks acceptance. Do not call frame-hash agreement a fresh full-byte comparison.
- On Mac, the SDL window visibly renders the CPU frames and movement, turning, shooting, door interaction and exit are checked. A scripted recording/replay agrees with the headless path. A headless skip does not satisfy this criterion.
- Unsupported/corrupt WAD input fails with a diagnostic; failed build and test stages cannot be counted as successful output comparisons.
- Existing Extended source/core boundary code and pin stay unchanged. Run the relevant current core checks after import; broaden compiler tests only if a concrete change or regression warrants it.
- Document exact commands, host, revisions, results, skipped checks and limits.

## Reference portability and historical hashes

The original headless oracle uses CommonCrypto and a Mac-specific Makefile. The first import runs its full C-reference replay gate on Mac only. Debian's required evidence is the five IWAD-independent comparisons; Debian C-reference replay and playable-window support remain unverified until a separate portable hash/build adaptation is implemented and tested.

Preserve the original R007 patch, including its recorded FNV offset basis `1469598103934665603` (the standard value would end in `...6037`). The historical `demo1_hashes.tsv` was produced with that value. Import that one 463,676-byte fixture at its recorded path/hash, not its surrounding research archive. Keep its legacy-hash interpretation explicit and do not repair the constant or regenerate this golden during migration. Later patches/comparators may use other hash fields; identify which field each gate compares.

## Limits

This does not add menu, automap, save games, sound, level transitions or respawn features absent from the predecessor's documented playable slice. It does not certify long-running arena execution, zero allocation per frame, performance, GPU rendering, WASM or all-core startup. Those require separate work and fresh measurements. Importing a DOOM example does not make general graphics a supported Extended backend.

## Delivery

Follow the [implementation plan](0006-doom-hosted-import-plan.md). Planning does not authorize execution, dependency pin changes, publication or main integration.
