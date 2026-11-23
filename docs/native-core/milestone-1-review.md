# Milestone 1, reviewed criterion by criterion

[Roadmap](../roadmap.md) Milestone 1. Each criterion is taken on its own, with
the evidence that bears on it and what that evidence does not cover.

The original measurements below are **Debian**, LLVM/Clang 23.1.1, against Extended `9cacfd4`
with fork `core/selected-root-seam` `00218233` and `core/input-ledger`
`cad0ad14`. They are historical evidence; the integration update below records the newer
pinned build and links the separately measured Mac results.

---

### 1. A clean checkout builds using documented, pinned dependencies without a predecessor checkout

**Met for the initial native slice after pinning.**

At this review the compiler was pinned at `cad0ad148af00b98a3de8a384c18a3cabe15bc1a`,
including both the seam and input ledger; the current pin is the commit
`vendor/spinel` records. The [reproduction commands](reproducing.md)
use `vendor/spinel`, without a predecessor or separate compiler checkout.
[Mac validation](macos-validation.md) records the fresh pinned compiler and
out-of-tree native-tool build, product-driver checks and fixture execution.
The other criteria below retain their original narrower Debian evidence and
limitations; pinning does not broaden the admitted language subset.

---

### 2. A minimal hosted Ruby program runs with the selected Spinel runtime

**Met.** `make test` on `cad0ad14`: 3543 pass, 0 fail, 0 error. The acceptance
program also runs through ordinary `spinel` with no `--core` and prints the same
answer as the core-backed build.

*Not covered:* this is the default configuration. It says nothing about the
arena or the core path.

---

### 3. A core function produces a standalone object without linking Spinel runtime or GC

**Met, at the object.** The core object is 624 bytes, defines the mapped symbol
and nothing else externally, has **0** undefined symbols and **0** collector
symbols.

*Not covered:* the executable is not runtime-free and is not claimed to be —
1664 `sp_*` symbols and 3 collector entry points are linked into it by design.
The independence claim is about the object, measured at the object.

---

### 4. A hosted program invokes that object through the agreed ABI and produces the expected result

**Met on Debian.** `puts lower(7, 3)` prints 3, agreeing with CRuby and with
ordinary Spinel. Four operand orderings and the signed limits agree with CRuby.

The routing is proved rather than assumed: a deliberately wrong core object
returning 999 makes the program print 999. A leftover hosted body would have
printed 3 and made the arrangement look correct.

*Not covered:* the ABI is **internal** — a symbol, parameter list, return type
and calling convention for one target, regenerated per build. No public numeric
interface exists, and none is proposed here.

---

### 5. Checks reject forbidden allocations, dependencies, calls and boundary usage, including cases that would otherwise link or run

**Met in part.**

What is rejected, each measured: arithmetic, a `nil` result, `Float` and
`String` arguments, loops, the reserved minimum, a method with no caller, an
unknown root, a `require`, and a caller outside the closure.

The case that **would otherwise link and run** is covered and was real: under
`--int-overflow=promote` the hosted boundary boxes to `sp_RbVal` while the core
path lowers machine-width integers. A symbol carries no types, so it linked and
the program printed 0 instead of 3, with the artifact gate passing it. The
prototype is now checked against what the core path can define.

*Not covered:* forbidden **allocations** and buffer misuse are not tested,
because the admitted subset cannot express them. They are outside the envelope
rather than rejected by a check, and that distinction is not cosmetic — a later
widening will need its own rejections.

---

### 6. Reachable external calls and compiler support routines have an explicit validation policy

**Met for this subset.** The policy is: the core object must have **no**
undefined symbols, checked by `core-artifact-gate`, not permitted by a symbol
prefix. Decision 0005 explicitly refuses a broad prefix allowance, and none is
used.

*Not covered:* a compiler-support dependency — the decision allows one under an
explicitly reviewed contract — has never arisen, so the policy has never had to
admit anything. It is a rule that has only ever said no.

---

### 7. Supported scalar behaviour compared against a reference, including boundary values and agreed failure cases

**Met.** Against CRuby: `lower(7,3)`, `(3,7)`, `(5,5)`, `(-9,-2)`, and at the
signed limits `(INTPTR_MAX, 0)`, `(INTPTR_MIN+1, 0)`, `(INTPTR_MIN+1,
INTPTR_MAX)`. The reserved minimum is refused rather than answered.

*Not covered:* one shape of program. No arithmetic, no failure behaviour, since
the subset admits neither.

---

### 8. Documentation includes build commands, supported forms, rejection examples, and honest limitations

**Met.** [Reproducing](reproducing.md) has the pinned build commands;
[the envelope](supported-envelope.md) has the admitted forms, measured Debian
refusals and runtime-presence figures. Mac results are recorded separately.

---

### 9. Imported implementation and fixtures have recorded provenance and required notices

**Met** for the arena import, in [provenance](../provenance.md). The native core
work is not an import: it is written here against upstream's own interfaces, and
the vendor changes are two named branches with their base recorded.

---

## Integration status

The pinned build closes criterion 1. The other criteria retain the limited
scope described above, including the partially measured allocation/buffer
criterion. This is the initial scalar native connection, not general Ruby
support or a buffer implementation.

The runtime-free claim concerns the core object; the executable contains the
hosted runtime. The external-call policy requires an empty undefined-symbol
set and does not introduce allowances for platform functions.

The separately measured [Mac validation](macos-validation.md) now includes the
product driver and shared artifact gate, as well as fixtures, input-ledger
publication and eligibility checks. Historical Debian counts above are not
relabelled as Mac results.
