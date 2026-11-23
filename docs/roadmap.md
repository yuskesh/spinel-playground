# Roadmap

This roadmap records the implemented scope on `main` and the acceptance work
that remains. A route's existence does not establish arbitrary Ruby support,
every platform combination, or completion of another route's milestone.
Build commands and environment requirements are in [Building and testing](building.md).

## Foundation: native core and full separation

The baseline compiler is pinned at
`4e0a59bd999e614bd8b2ece72ec2b8d0cbbc5522`: the fork's local patch stack
replayed onto upstream head `f8ff01939` at the 2026-11-14 synchronisation
([provenance](provenance.md#upstream-synchronisation-2026-11-14)), which
carries upstream's `--gc=none` itself, plus spinel-mlir's M1, M2 and M3′ with their settings
([Patch 2](provenance.md#patch-2-spinel-mlir-m1m3-the-spinel_facts-contract-v2-2026-10-25))
and M4′, the typing probe
([Patch 3](provenance.md#patch-3-spinel-mlir-m4-the-typing-probe-2026-10-27)),
and the collector's opt-in event record
([decision 0036](decisions/0036-gc-event-record.md)).
Its imported components and local patches are recorded in
[provenance](provenance.md).

The initial native scalar connection is implemented on Debian x86_64 and
macOS arm64. The Extended driver snapshots inputs, checks a selected ordinary
Ruby closure, emits its hosted declaration and core object, checks that object,
and links one executable. The executable retains the hosted runtime; the
selected core object must have no undefined dependencies. Reproduction and
host-specific evidence: [native core guide](native-core/reproducing.md) and
[the milestone review](native-core/milestone-1-review.md).

| Accepted boundary | Delivered behavior | Checks |
|---|---|---|
| Ordinary-source native scalar slice | inferred integers, comparisons, conditional selection, local bindings and checked integer arithmetic (decision 0015); `puts lower(7, 3)` links to the selected object. Bitwise `& | ^ ~` (decision 0042 stage 1), the shifts `<< >>` under Ruby's count rule (stage 2), `abs` and `**` (stage 3), and the named wrapping and unsigned word forms with decision 0022's intrinsics (stage 4) are admitted. | [driver](../tests/native-core/driver.sh), [ledger](../tests/native-core/ledger.sh), [arithmetic](../tests/native-core/arith.sh), [eligibility](../tests/core-eligibility/run.rb) |
| Declared standalone function | explicit scalar ABI, an object callable from C, dependency screening and declared trap behavior | [core acceptance](../tests/core/run.sh) |
| Checked numeric/buffer CORE boundary | checked arithmetic, borrowed buffers, explicit aliasing and size rules, status failures, generated Full adapters and packaging | [boundary suites](../tests/core-boundary/run.sh) |

The third row is the implemented extension under
[decision 0007](decisions/0007-doom-core-preparation.md); its
[capability record](core/stage1-capability.md) describes the extracted DOOM
slices. It has a different interface from the ordinary-source scalar selector.
General Ruby object pointers, unknown external effects and allocating reachable
callees do not become core merely because a particular run avoids collection.

## Integrated target and application routes

The following routes are implemented and merged. Their documented subsets,
platform contracts and suite prerequisites are the scope of the capability.
The [examples index](../examples/README.md) links their build/run commands.

| Route | Delivered scope | Checks |
|---|---|---|
| Freestanding target profiles | declared kernels on Cortex-M33 and RV32 under Zephyr/QEMU and wasm32 under node/workerd; scalar/buffer boundaries, traps and platform externs | [target lanes and coverage](../tests/freestanding/README.md), [runner](../tests/freestanding/run.sh) |
| Full with no RTOS | a program with the hosted runtime and its collector on a Cortex-M with no operating system, linked with picolibc built with LLVM 23.1.1, under QEMU's mps2-an521, and run once by hand on the FRDM-MCXN947 board and on a Raspberry Pi Pico (RP2040, Cortex-M0+) ([0037](decisions/0037-bare-metal-full.md)). Integer is 32 bits; no files, threads or `Fiber` | [runner](../tests/bare-full/run.sh), [tool](../tools/bare-full/README.md) |
| Full on Zephyr's POSIX layer | a program with the hosted runtime and its collector in a Zephyr v4.4.2 application on the FRDM-MCXN947, on Zephyr's POSIX layer, sockets and picolibc, run once by hand on the board ([0038](decisions/0038-zephyr-posix-full.md)). Supervisor mode only: the program faults in the POSIX layer in a user-mode thread. No file system; integer is 32 bits | [runner](../tests/zephyr-full/run.sh), [tool](../tools/zephyr-full/README.md) |
| WASM/edge packaging | `wasm32-wasip1`, Workers and Fastly scaffolds, explicit host bridges, edge-twin device-log replay; local workerd/Viceroy/QEMU execution. | [edge runner](../tests/edge/run.sh), [capability checks](../tests/edge/capcheck_rc.rb) |
| Tensor and image computation | tensor declarations, fusion and StableHLO imports through IREE; CPU and Apple GPU/Metal paths | [tensor/image runner](../tests/tensor/run.sh) |
| Differentiation | declared allocation-free Float methods through Enzyme, custom rules and gradient/HVP/JVP gates; corresponding freestanding lanes | [host runner](../tests/grad/run.sh), [target runner](../tests/freestanding/run.sh) |
| GPU graphics | DOOM Job IR raster kernels through IREE/Metal, and a declared shader subset to SPIR-V/WGSL/MSL | [raster runner](../tests/raster/run.sh), [shader runner](../tests/shader/run.sh) |
| Linux eBPF | Ruby HTTP-server/probe integration, plus SpBPF MLIR/ELF generation and Go/XDP bindings | [Ruby checks](../tests/ebpf/run.sh), [Ruby live checks](../tests/ebpf/live.sh), [SpBPF](../tests/spbpf/run.sh), [Go](../tests/ebpf-go/run.sh), [Go live checks](../tests/ebpf-go/live.sh) |
| bcc tools' BPF side | 35 bcc tools of [`tools/spinel-bpf-mlir`](../tools/spinel-bpf-mlir/README.md) built end to end from this Spinel's `spinel_facts` v2 facts, through spinel-mlir's consumer in [`tools/spinel-mlir`](../tools/spinel-mlir/README.md), to bpf-mlir. The owner accepted the first 28 on 2026-10-27; all 35 of v0.8.0 met the same criterion on one approved oracle run. Linux x86_64 only; no program is loaded here | [the route and its acceptance](building.md#the-bcc-tools-bpf-side-spinel-bpf-mlir-and-spinel-mlirs-consumer), [facts](../tests/bcc-facts/run.sh), [Go tests](../tests/spinel-bpf-mlir/run.sh), [consumer](../tests/spinel-mlir/run.sh) |

GPU execution needs the named device/runtime; Metal checks are unavailable on
Linux. Live BPF attachment has separate Linux kernel and capability requirements.
Local edge validation does not establish a production cloud deployment; see
[Workers limits](edge/workers-limits.md). Suite skips and unported rows are
coverage limitations, not successful acceptance of those paths.

### CORE applications on Zephyr: decision 0014

[Decision 0014](decisions/0014-core-applications-on-zephyr.md) is implemented
and merged: its contract entered `main` at `7a7f453`, and its implementation
was merged at `8fbe4d1` into the integration subsequently merged to `main`
at `59c6a83`.

The application driver turns state, timer triggers, channels and board-member
declarations into firmware with CORE entries, generated glue and evidence for
providers, stacks and interrupt sources. It also provides trace verification
and ring-buffer stress checks. `mps2/an521` is built and run under QEMU;
FRDM-MCXN947 is built, without a claim of execution on the physical board.

Use the [application interface guide](core/applications.md) and the
[application suites](../tests/app/run.sh). The
[plan's coverage record](decisions/0014-core-applications-on-zephyr-plan.md)
records what the verification can and cannot refute. Missing Zephyr tools can
skip target checks; `REQUIRE_ALL=1` makes those skips fail. This is not support
for arbitrary boards or uncontracted platform calls.

## DOOM: integrated routes and remaining acceptance

Hosted CPU DOOM, headless replay and the native CORE route coexist with the
GPU raster route. The native `-core` build links generated input, step and
render entries; Full supplies setup, storage, input acquisition and display.
Without those entries the build's stub refuses the CORE route at session open.
Commands and coverage are in the [DOOM guide](doom.md),
[CORE source guide](../examples/doom/core/README.md) and
[CORE lane runner](../tests/doom-core/run.sh).

| Stage | Current state | Acceptance boundary |
|---|---|---|
| CORE preparation (0007) | implemented and accepted native numeric/buffer slices | [stage-1 record](core/stage1-capability.md), [boundary suites](../tests/core-boundary/run.sh) |
| CORE DOOM (0008) | native entries, source packing, state/closure/resource checks and playable routing are integrated | [execution plan](decisions/0008-doom-core-migration-plan.md), [CORE suites](../tests/doom-core/run.sh); integration of individual routes is not a claim that every milestone criterion or host/input configuration is closed |
| Freestanding preparation | target profiles, platform externs and Zephyr application infrastructure are implemented | [target lanes](../tests/freestanding/run.sh), [application suites](../tests/app/run.sh); these checks cover their declared kernels and applications |
| CORE DOOM on FRDM-IMXRT1186 (0021–0025) | decision 0008's three CORE entries, built at 32 bits ([0022](decisions/0022-core-word-arithmetic.md)), run headless on the board's Cortex-M7 ([0023](decisions/0023-doom-on-the-cortex-m7.md)), called from a CORE Ruby application under Zephyr ([0021](decisions/0021-doom-core-on-frdm-imxrt1186.md)). The session at open is prepared on the host and written to the NOR as an image; the board loads no WAD. Every frame's FNV-1a 64 digests must be the recorded frames: DEMO1 to DEMO3 passed 79 of 79 on 2026-10-22 (recorded in 0025). The frames are also sent over Ethernet to a host viewer ([0024](decisions/0024-doom-frames-over-the-network.md)), and a separate application plays from a host keyboard ([0025](decisions/0025-doom-play-over-the-network.md)) | [board lane](../tests/doom-core/rt1186.sh), [play lane](../tests/doom-core/rt1186-play.sh), [lane guide](building.md#verifying-dooms-three-core-entries); needs the board and its probe host. The board loop is not a realtime claim |
| Two cores on FRDM-IMXRT1186 (0027) | the M7 runs DOOM's `pair.rb` and the M33 a companion; a declared channel carries the console from the M7 to the M33, which relays it. DEMO1 to DEMO3: every frame the recorded one; polling every 1 ms, the wait from put to get had a mean of 491.03 us (DEMO1) and a p99 of at most 1092.263 us | [decision 0027](decisions/0027-amp-two-core-channel.md), [results](decisions/0027-results.md), [board lane](../tests/doom-core/rt1186.sh) with `RT1186_PAIR=1` |
| MU doorbell (0028) | ring ABI version 4: a put rings the MU when the consumer waits, and the M33's relay is released by the interrupt, every 10 ms at the latest. DEMO1 to DEMO3 passed 76 of 76; the mean wait was 47.677 us (DEMO1) to 51.64 us (DEMO3), p99 at most 68.263 us; the board controls passed 32 of 32 | [decision 0028](decisions/0028-mu-doorbell.md), [results](decisions/0028-results.md) |
| Freestanding DOOM | proposed; no complete target deployment is claimed. This row is the whole game on a target. The board rows above run only the three CORE entries, with the session prepared on the host | a selected target still needs whole-game closure, startup/storage/platform integration and target execution evidence |

**Open, the owner's decision:** from
[0028's results](decisions/0028-results.md#open-items), keeping the number of
the message whose wait was the longest, which adds an ABI word, and a better
drift estimate than the rounds' midpoint. The drift's cause, a nominal 33/10
clock ratio against the real one, is not confirmed.

The GPU raster suite checks demo completion, job refusals and GPU frame counts.
CPU/GPU frame comparisons and other reference-oracle runs have separate scope;
they are not implied by a successful default raster run. The hosted game also
retains its documented limits, including absent audio, menus and level transitions.

## Memory policy and future work

A native build without a collector is upstream's `--gc=none`, under
[decision 0003](decisions/0003-gc-and-arena-build-modes.md) as revised on
2026-11-01: allocation is reclaimed at exit, `GC.start` is a no-op, and the
[pair suite](../tests/gc-arena/run.sh) compares it with the collected build.
Threads, C extensions and `--exceptions=abort` are accepted upstream and not
verified here. The WASM command-mode request-arena build is `--gc=none`,
checked by [its suite](../tests/edge/arena.sh); memory is reclaimed when the
instance dies. The suite records the pinned compiler's Integer catch/throw
defect separately from passing semantics checks, including its reproduction on
the ordinary build.

**Proposed only:** a scoped arena that coexists with a collected heap. Its
ownership, escape, aliasing and capacity-failure contracts remain to be decided;
the existing process/instance lifetime choices do not establish that coexistence.

Further target, language-subset and ABI extensions require concrete contracts
and acceptance cases before implementation. Keep frontend facts, lane semantics,
artifact generation and runtime integration separate, and retain a normal
hosted C path. An imported backend must carry its reproducible build path,
notices and regression checks; a backend name alone is not delivered behavior.
