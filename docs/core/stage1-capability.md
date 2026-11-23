# Decision 0007 stage 1: what is being presented

This is the capability offered for integration under decision 0007's last
planning bullet. It states what was built, what was measured, and — at the
same length — what it does not establish.

**Accepting this is not evidence that anything beyond it works, nor approval to
migrate the game, nor approval to move the dependency pin.** The decision says
so and this page repeats it because a summary is the easiest place for a
boundary to go quiet.

## What it is

A checked CORE boundary that a Full Ruby program can call: a contract file, a
generated C header, a CORE object that needs nothing from the host, and a
generated Full adapter with a registry that lends the kernel buffers the caller
owns.

The status ABI is decision 0007's own five values — `0 OK, 1 ARGUMENT,
2 ARITHMETIC, 3 BOUNDS, 4 CAPACITY` — and never a forwarded predecessor trap
code. A failure returns a status and writes no result.

## What it carries

Thirteen entries, extracted from the Full DOOM tree and held to it:

| capability | entries | original |
|---|---|---|
| fixed point and angle normalisation | 5 | `lib/doom/fixed.rb` |
| wall column, plane span, fuzz column | 3 | `lib/doom/executor.rb` |
| thinker list and mobj slot allocator | 5 | `lib/doom/game.rb` |

Each is run against the ORIGINAL Full code, not against a transcription of it:
the fixed-point lane loads `Doom::Fixed` unmodified; the framebuffer lane
drives `Doom::JobExecutor`'s own `exec_wall`, `exec_span` and `exec_masked`;
the slot lane drives `Doom::Game`'s own thinker and mobj methods, beside an
independent reference model that derives the link fields rather than assigning
them. Every adaptation is listed in the source that makes it.

## What was measured

On Debian 13 x86_64, clang 23.1.1, ruby 3.3.8, at `57bcc74` on
`feat/doom-core-preparation` — the commit that added the thirteenth entry — on
an incremental native build. `tests/core-boundary/run.sh`: **nine lanes, nine
passed**. The runs and their table of hosts and toolchains are in
[provenance](../provenance.md).

schema 73; arithmetic 171 with 66 of 66 executed; buffers 115 with 53 of 53 and
both sanitisers; adapter 62 with 45 of 45; capabilities 49; framebuffer 22;
slots 24; artifacts 30 over 13 entries; closure 32 over 27 constructs.

Those are the acceptance counts at `57bcc74`. The review hardening of
2026-09-12 added one original-digest check to each of the capabilities,
framebuffer and slots lanes, so they now count 50, 23 and 25; made
`tests/native-core/run.sh` Darwin-aware, where it passes 18 of 18; and made
`REQUIRE_ALL=1` fail a lane whose sub-lane could not run for want of a tool.
The other counts are unchanged. See [provenance](../provenance.md).

The documented build was reproduced from a clean checkout — a fresh clone, its
own `make deps`, the pinned compiler, the contract reader, the native tools —
every step exit 0, then nine of nine. That one was run at `f08a976`, **the
commit before the angle normalisation was extracted**, so it reproduced the
build and the nine lanes over twelve entries rather than thirteen; the
thirteenth is covered by the incremental run above and not by a second clean
build.

macOS arm64 built this branch from a clean dependency bootstrap and ran the
same nine lanes under `REQUIRE_ALL=1`, so no lane could silently not run:
**nine of nine**, plus `tests/doom/run.sh` five of five.

Existing checks on Debian: core eligibility OK, core acceptance 33 of 33,
native CORE driver, ledger and run all exit 0, hosted DOOM five of five.

Each capability answers the same through a direct C harness and through the
Full adapter, from one harness source compiled twice — and the adapter build is
required to fail to link without the adapter, so "two paths" is checked rather
than assumed.

## What it does not establish

**The native-core checks pass on macOS under the documented toolchain.**
The recorded results after review hardening are driver 43/0, ledger 23/0 and
`tests/native-core/run.sh` 18/0, plus the nine-fixture Mach-O probe. The earlier
driver and ledger failures came from missing environment exports; the ledger
now explicitly refuses an unspecified compiler instead of using a Debian path.
`run.sh` now handles Darwin's library and symbol-prefix differences. Export
`LLVM_PREFIX`, `CLANG`, `CC` and `NM` as [the build guide](../building.md)
requires. The earlier vendor build used Apple clang and was replaced by a
clean build with LLVM 23.1.1; [provenance](../provenance.md) records the corrected
measurements and the superseded evidence separately.

**The freestanding leg still cannot be exercised on macOS with the supplied
profiles.** `tests/core/run.sh` hard-codes the x86_64-linux freestanding profile
and no arm64 macOS profile exists. This limitation predates this work.

**Performance is not measured.** The decision puts it after correctness and
requires copying cost reported rather than hidden in kernel-only timings.
Neither has been done and no timing is claimed. The adapter moves buffers a
cell at a time, by design, and nobody has said what that costs.

**The rest of DOOM is not close.** `docs/core/doom-closure-gaps.md` measures
it: of 573 `def`s and a further 381 accessor methods in the Full tree, 72 hold
nothing the checked subset refuses — and that 72 is an upper bound, not a
count of what could be extracted. Instance state is in 83% of them, a branch
with no else in 49%. Three of the gaps — instance state, dispatch, allocation —
are the shape of the program rather than of the subset.

**One adaptation is not a spelling change** and is marked as such: the thinker
sweep is bounded, so a cyclic list answers `CAPACITY` where the original and
vanilla walk forever.

**One ABI asymmetry has a consequence worth designing for**: a refused `invoke`
poisons the mutable participants, so a Full caller that exhausts a fixed
capacity loses access to the arrays, where the hosted game raises and carries
on with the list intact.

## Where to look

- `docs/decisions/0007-doom-core-preparation-plan.md` — the tasks and their state.
- `docs/core/doom-closure-gaps.md` — what a whole-DOOM closure would still need.
- `docs/provenance.md` — the recorded results, Debian and macOS, and corrections to historical evidence.
- `docs/core/buffer-boundary.md` — the contract file, the checked kernel, the
  buffer rules and the generated Full adapter, with usage.
- `tests/core-boundary/run.sh` — every lane, with its counts and its status.
