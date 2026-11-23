# Project Foundation and GC Control: Work Report

- Report date: 2026-09-10
- Implementation and integration period: 2026-09-09
- Project: Spinel Extended
- Reviewed main revision: `9913c3a70e1ec05f209bb7a3d16a45226661bf3b`
- Spinel dependency: `5bc45ec19a372c6f4da29485a7ce35c81b9751cc`
- Status: project foundation, minimal scalar core slice, and initial process-arena mode integrated; full-to-core bridge paused and not integrated.

## 1. What is now possible

### Build ordinary Ruby with or without a collector

The main outcome is a whole-program build choice. An ordinary Ruby program can be compiled with the default collecting runtime, or with `--arena`, which selects a process-lifetime arena without running the collector.

The arena mode does **not** require `freestanding_def`, RBS declarations, an FFI boundary, or a different Ruby integer width. It continues to allow allocation. The memory managed by the arena is retained until process exit; it is not collected or reset during execution.

The accepted initial scope is short-lived, single-threaded programs. This is not a guarantee for arbitrary Ruby programs or long-running workloads.

| Capability | Current behavior |
|---|---|
| Normal compilation | Uses the existing GC-enabled runtime by default |
| Arena compilation | `--arena` selects the arena compile definition and runtime archive together |
| Retaining objects | Values can remain reachable through locals and globals for the process lifetime |
| Explicit resource management | Explicit close, block cleanup, `at_exit`, and `END` retain their existing behavior in the verified cases |
| Capacity exhaustion | Fails with a diagnostic and nonzero exit; no recoverable allocation-error contract was introduced |
| GC operations | `GC.start`, `GC.compact`, and `GC.stat` are rejected in arena mode |
| Threaded execution | Thread/Mutex/Queue configurations are rejected in arena mode |
| C-only output | Combining `--arena` with `-c` or `-S` is explicitly rejected |

The default arena limit is 64 MiB, adjustable with `SPINEL_ARENA_MAX_MB`. It bounds arena-managed chunk storage, **not total process memory**. Container backing storage, regexp and temporary buffers, bigint limbs, and fiber stacks can be allocated outside that accounting.

Collector absence was checked on representative arena executables, with collector-enabled executables as controls. GC root bookkeeping remains present: retaining roots is distinct from running a collector.

### Generate a standalone scalar core object

A separate, earlier result also remains on main: the existing MLIR freestanding route was imported for a minimal i32/i64 scalar slice. A Ruby method with `freestanding_def` can produce an object and C header and be called from a C program.

The verified objects depend on the declared `spinel_trap` hook rather than Spinel runtime or GC linkage. Checks distinguish internal i64 arithmetic overflow from narrowing an i64 result to an i32 return value, and reject representative forbidden operations and external dependencies.

This capability is separate from the whole-program GC choice. It does not mean that the hosted full tier and core have been connected on main.

## 2. How to use the GC build choice

The following example targets the validated Debian environment, with LLVM/Clang/MLIR 23.1.1 installed under `/opt/llvm-23.1.1`. Run from a clean checkout of the report revision, with Ruby available for build/test helpers.

```sh
git submodule update --init --recursive
make -C vendor/spinel deps
make -C vendor/spinel -j8 CC=/opt/llvm-23.1.1/bin/clang
make -C vendor/spinel arena-archive CC=/opt/llvm-23.1.1/bin/clang

mkdir -p build
printf 'puts 6 * 7\n' > build/example.rb

vendor/spinel/spinel build/example.rb \
  --cc=/opt/llvm-23.1.1/bin/clang -o build/example-gc
vendor/spinel/spinel build/example.rb --arena \
  --cc=/opt/llvm-23.1.1/bin/clang -o build/example-arena

./build/example-gc
./build/example-arena
```

Both executables are expected to print `42`. They compile the same source using different runtime configurations. Raising the arena limit for a particular execution takes this form:

```sh
SPINEL_ARENA_MAX_MB=128 ./build/example-arena
```

The compiler's `--cc` option is explicit because Spinel's own generated-C compilation does not select its compiler through the `CC` environment variable. Changing compilers in an existing build tree requires a clean rebuild; follow the detailed [building instructions](../building.md) as they stood at the report revision, `9913c3a`.

These commands illustrate the implemented interface. No new build or runtime test was executed while writing this report.

## 3. Work completed and architecture decisions

### Repository and dependency foundation

- Created the private spinel-extended repository, with English development guidance, architecture direction, roadmap, contribution rules, and decision-record conventions.
- Fast-forwarded `yuskesh/spinel:master` to upstream `matz/spinel:master` at `d9eb84566eac0fce8b50cd4096e8594d6f303643`, incorporating 1,121 commits without a conflicting fork-side history.
- Added Spinel under `vendor/spinel` as a pinned Git submodule. Predecessor checkouts are reference and migration sources, not build dependencies.
- Established Debian as the primary full-suite environment and macOS as a compatibility environment. This report claims no completed macOS full-suite result.
- Installed the official LLVM 23.1.1 release on Debian, including Clang and MLIR, and verified its release attestation. Existing system toolchains and global PATH were preserved.

### Reuse of existing compiler work

The migration source was `spinel-llvm` revision `f8ad13c6d9dc990b116ba1c842c7881232f29585`. Its in-process contract reader worked against the new upstream pin without a source adaptation in the initial probe. The minimal freestanding emitter/checker also built against LLVM 23.1.1 with CMake packaging adaptations, including RTTI compatibility; no LLVM 23 C++ API rewrite was needed for that measured slice.

The scalar slice landed on main at `397f7c0e0c15406930b51d88839dfbf3e01c99dd`. Required code, allocation vocabulary, declarations, fixtures, provenance, and focused English documentation were included. Unimplemented backends were not advertised as available.

### Scope correction: GC control is not an external ABI

An initial continuation explored a hosted-to-core FFI bridge. It exposed silent inbound integer narrowing and conversion of nil or Float values, and led to caller/callee ABI checks. An alternative RBS-assisted upstream C route was investigated but was not adopted as a replacement for the existing MLIR core route.

The project direction was then corrected: the immediate goal was GC control for ordinary Ruby, not externally published kernels or a new function-boundary DSL. The bridge was stopped and remains outside main on `feat/full-to-core-bridge` at `38f1813043d9b54b7db28a7b90d016ff9ea464ca`.

The accepted GC design selects the memory-management configuration at program build time. Its initial noncollecting mode uses a process-lifetime arena. No request reset, arena-to-longer-lived-global escape rule, new ownership model, or hosted exception recovery ABI was introduced.

### Arena implementation

The fork branch `arena/process-lifetime` supplies the runtime and driver changes. Extended now pins `5bc45ec19a372c6f4da29485a7ce35c81b9751cc`; fork master remains at the upstream synchronization revision.

- `SP_PROCESS_ARENA` selects the arena runtime paths.
- `libspinel_rt_arena.a` is built separately from the default and threaded archives.
- `--arena` couples generated-translation-unit configuration with the matching archive.
- GC rejection uses markers emitted at actual GC code-generation sites, rather than matching Ruby names or arbitrary C string contents.
- Allocator guards cover initial state, size alignment, header additions, chunk sizing, capacity arithmetic, and invalid or unrepresentable capacity settings.
- Root bookkeeping is retained after removing it caused differences around nonlocal exits. This restores the measured default behavior; it is not a general repair of the upstream C `setjmp`/`longjmp` value rules.

The final integration was a fast-forward to `9913c3a`, including the acceptance of [decision 0003](../decisions/0003-gc-and-arena-build-modes.md). The dedicated fork branch remains the dependency source; the fork master and the paused bridge were not merged as part of this integration.

## 4. Validation and its limits

Execution evidence below comes from the Debian implementation reports and the integrated repository records. The coordinating review inspected source diffs and whitespace checks; it did not independently repeat the Debian suites.

The validated environment was Debian 13 x86-64, LLVM/Clang 23.1.1, Ruby 3.3.8, and `umask 022`.

| Check | Recorded result | Meaning |
|---|---|---|
| Default upstream `make test` | 3,543 pass, 0 fail, 0 error | GC-enabled configuration nonregression |
| Direct arena allocator guards | 5 pass, 0 fail | Extreme-size handling; removing guards made four checks fail |
| Product-path corpus comparison | 3,543 cases; 267 declared non-pass/pass transitions matched | No undeclared verdict transition between configurations |
| Extended GC/arena acceptance | 28 pass, 0 fail, 1 recorded reference difference | Focused retention, control flow, resources, refusal, capacity, and artifact checks |
| Existing scalar core acceptance | 33 pass, 0 fail | Imported core slice remained functional with the new dependency |

After integration, the GC/arena and core acceptance scripts were reported passing again. The default full suite was not rerun solely for the final decision-status documentation change.

The product-path corpus must not be confused with the default Makefile suite. It invokes the compiler driver through a separate harness and already has failures in its collector-enabled baseline.

| Collector verdict → arena verdict | Cases |
|---|---:|
| pass → pass | 3,276 |
| pass → rejected | 132 |
| pass → capacity | 5 |
| error → error | 91 |
| fail → fail | 28 |
| no expectation → no expectation | 3 |
| error → rejected | 5 |
| fail → rejected | 2 |
| no expectation → rejected | 1 |
| **Total** | **3,543** |

Thus 3,276 programs matched successfully in both configurations. Refusals and capacity exhaustion are separate outcomes, not successful Ruby executions. The 122 cases still failing or lacking an expectation in both legs do not establish arena correctness; neither do the eight baseline-problem cases that become refused.

The initial arena suite run using global Makefile overrides contaminated build configurations and is invalid evidence. It was replaced with separated archives and a product-path harness. Earlier incorrect counts were superseded by machine aggregation of the final TSV records.

Default generated C was compared against pristine upstream for the same corpus: 3,539 byte-identical outputs and four cases rejected by both, with no differing generated output. Runtime artifact comparisons also supported default-path nonregression. One deliberate driver change remains: thread/fiber marker matching is anchored to actual marker lines, avoiding a false threaded-runtime selection caused by ordinary string contents. This is not claimed as universal binary identity.

## 5. Defects found and corrected during the work

Review and negative controls identified issues beyond ordinary successful builds:

- An omitted cell-scan helper caused arena compilation failures after importing an older patch.
- Disabling root macros changed nonlocal-exit behavior; the optimization was removed.
- Plain substring detection rejected programs that merely printed GC-related text; generator markers replaced it.
- Unchecked allocation arithmetic and initial NULL-pointer subtraction required explicit guards.
- Unquoted compiler commands broke test invocation when ccache supplied a multiword compiler command.
- Test harnesses initially ignored exit status or accepted arbitrary shared differences from CRuby; those checks now fail on new differences and pin the one known exception precisely.
- A PATH-selected Clang 19 could not consume LLVM 23 IR. The existing core test runner now selects the configured compiler by default and diagnoses a detected version mismatch before cascading failures.

Mutation checks demonstrated that the relevant acceptance checks can fail. Reported success is consequently stronger than merely observing that a happy-path example runs, but remains limited to the recorded cases.

## 6. Remaining work and limitations

- Arena mode is accepted only for the initial short-lived, single-threaded scope. Long-running use, concurrent worker arenas, and arbitrary coexistence with a long-lived GC heap are not established.
- Implicit finalization does not occur. File and directory handles must be explicitly closed where needed; arena capacity does not bound every external allocation or resource.
- The focused control-flow fixture has a pinned inner-ensure difference from CRuby in both configurations. It is an existing compiler difference, not repaired by this work.
- The product-driver collector baseline has 96 errors, 30 failures, and four missing expectations, despite the separate Makefile suite passing. Unresolved cases remain explicitly unverified.
- The hosted-to-core bridge, inbound validation policy, and complete checked full/core boundary remain paused and unintegrated.
- Buffer, Float, unsigned-width, wrap, cross-target, and additional backend coverage were not established by the minimal scalar migration. No completed macOS result is claimed here.
- Original Extended/predecessor contribution licensing remains undecided. Spinel MIT notices and identified copied-source attribution must be preserved; this work does not establish public-release readiness.

## 7. Revisions and supporting records

| Milestone | Revision |
|---|---|
| Initial upstream baseline | Spinel `d9eb84566eac0fce8b50cd4096e8594d6f303643` |
| Dependency adoption | Extended `c8fb507e130db8b6d0625868a0ff42b6c3af8f5b` |
| Debian baseline documentation | Extended `47cf68b091338fce452b6d5c2ab46c4a0c65f4d1` |
| Minimal scalar core integration | Extended `397f7c0e0c15406930b51d88839dfbf3e01c99dd` |
| Process-arena runtime pin | Spinel `5bc45ec19a372c6f4da29485a7ce35c81b9751cc` |
| GC configuration integration | Extended `9913c3a70e1ec05f209bb7a3d16a45226661bf3b` |

Supporting records are versioned to the report snapshot, `9913c3a`; the links go to their current versions in this repository:

- [Build and test instructions](../building.md)
- [Dependency and migration provenance](../provenance.md)
- [Accepted GC/arena decision](../decisions/0003-gc-and-arena-build-modes.md)
- [GC/arena acceptance runner](../../tests/gc-arena/run.sh)
- [Scalar core acceptance runner](../../tests/core/run.sh)

The final deliverable is a reproducible compiler foundation with an opt-in process-arena build mode, supported by focused tests and a separately recorded default-GC baseline. It is not a completed multi-target migration or a completed full/core boundary design.
