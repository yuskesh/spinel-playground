# Task 4: lowering the checked closure

Decision [0005](../decisions/0005-native-core-executable.md), plan task 4. The
ordinary Ruby source of the acceptance program becomes an executable whose
selected method is defined by an object the MLIR path produced.

Debian, LLVM/Clang 23.1.1. Nothing here is macOS or Mach-O evidence.

## What runs

```sh
SPINEL_SEAM=<checkout of core/selected-root-seam> tests/native-core/run.sh
```

The hosted half needs the `--core` seam, which is **not** in the pinned
`vendor/spinel`. `SPINEL_SEAM` points at an independent checkout of
`yuskesh/spinel` `core/selected-root-seam` at `00218233`; the Extended gitlink
is deliberately not moved.

Measured: **10 passed, 0 failed.**

```
def lower(a, b)
  a < b ? a : b
end

puts lower(7, 3)
```

No `freestanding_def`, no RBS, no hand-written FFI, and no inference call
inserted to make the types resolve. The evidence comes from the call the program
already contains.

## The three stages, and what each is not allowed to be

1. **Admission** — `checkEligibility` on the same module, not a second opinion
   about what is admissible. The closure that gets lowered is *the checker's*
   closure: selecting a different set here would mean the thing checked and the
   thing emitted are two different things.
2. **Selection and import** — `selectScalarProgram` and `importScalarProgram`,
   the same importer the freestanding lane uses. `ScalarImportOptions` is left
   default, so `freestandingTypes` stays false and no declaration-shaped
   boundary or trap policy can enter through this path. The overflow mode is
   `None`, which carries no policy and inserts no guard; that is what "no
   implicit trap" means here, and it is sound only because eligibility refuses
   arithmetic outright.
3. **Naming and emission** — the root takes the symbol **from the mapping the
   hosted compiler wrote**. It is not derived here. Every other function in the
   closure is made private, so the object exports the selected roots and nothing
   else.

One coupling is worth naming rather than hiding: the importer names a method
`sp_<name>` internally (`MlirGen.cpp`), and the adapter looks the root up under
that name before renaming it. That is the importer's convention, not the
mapping's, and it is the single place that depends on it — so when it is not
found, the diagnostic lists every function the module *does* define instead of
leaving the reader to guess.

## Measured

| | |
|---|---|
| `lower(7,3)`, `(3,7)`, `(5,5)`, `(-9,-2)` | agree with CRuby: 3, 3, 5, −9 |
| two call sites to one root | agrees with CRuby: 3, 1 |
| a helper closure (`pick3` calling `lower` twice) | agrees with CRuby: 3 |
| the helper closure's object | exports the root only; helper is internal |
| the core object's exported symbols | exactly the mapped symbol |
| the core object's undefined symbols | **0** |
| the lowered function's name | the mapped symbol, not the Ruby name |
| a stub core object returning 999 | prints **999** |
| the same source with `a + b` | refused, not eligible |

The stub is the load-bearing one. If the hosted body were still present, the
executable would print the right answer and the whole arrangement would look
correct while the core object did nothing.

## Ingress enumeration, and what it found

The task 2 report §4b required every call into a closure member to be
accounted for. Two programs showed why, and both were `CHECKED` before the rule
existed:

```ruby
def lower(a, b)          def lower(a, b) ... end
  a < b ? a : b          def pick3(a, b, c) lower(lower(a, b), c) end
end                      def other(y) lower(y, 1) end     # ingress into a HELPER
def unused(x)
  lower(x, 3)            puts pick3(7, 3, 5)
end
puts lower(7, 3)
```

Both linked and ran correctly, because `unused` and `other` are never called --
the top level admits no call to a non-member, so neither is reachable. That is
the reason they are now refused anyway: the safety came from the envelope being
narrow, not from anything checking it, and the argument each would pass has no
established domain. `unaccounted-ingress` names the caller and the callee.

The closure is computed root-downwards, so it records who the root *calls* and
nothing about who calls *it*; the enumeration is the other direction, walking
each top-level definition outside the closure for calls into it.

One defect found while writing it, by an existing test rather than by a new one:
`Reference` and `Integer` are both `int64_t` in the contract model's variant, so
reading the variant without consulting the field's `kind` turned the literals in
`[1, 2]` into node ids 1 and 2 and walked into unrelated definitions. The
control that catches it is `test_an_unrelated_definition_is_not_an_ingress`,
which existed before this change.

## Helper visibility, measured rather than assumed

A helper inside the closure is lowered into the same object and must not be part
of its interface. Setting MLIR's `private` visibility was **not** enough:
measured, the module printed `func.func private @sp_lower` and `nm` still listed
it as a global `T`. The conversion to LLVM keeps external linkage for a defined
function unless told otherwise, so the adapter sets `llvm.linkage = internal` as
well. After that the object exports `spc_<snapshot>_pick3` and nothing else.

This is the kind of thing the artifact check exists for: the module said the
right thing and the object did not, and only looking at the object showed it.

## Task 5: the driver

Reviewed once and rewritten. Five defects were found in the first version, and
one of them was a boundary the two halves disagreed about that **linked**.

### The boundary mismatch

Under `--int-overflow=promote`, inference boxes the hosted boundary to
`sp_RbVal` while this path lowers machine-width integers. A symbol name carries
no types, so the link succeeded and the program printed **0** instead of 3. The
artifact gate passed it: the object exported the right symbol, had no undefined
dependencies, and had text. Nothing compared the hosted *prototype* against what
the core path can define.

`spinel-core-emit` now reads the mapping's signature column and refuses a
boundary it cannot define, before anything is emitted. A mapping row without a
signature is malformed rather than unchecked — skipping the comparison would
make an unchecked boundary look like a checked one.

### `require` never reaches the eligibility checker

Measured, and the reason the dependency check is where it is: the frontend
consumes `require` **before the contract is written**. The ast face for a
program with a top-level `require "json"` is identical to one without it — same
node count, no `require` node — so no rule in the eligibility checker can refuse
it, and a top-level `require` was `CHECKED`.

A regex over the source is not the answer either. It misses `; require`,
`Kernel.require` and `send(:require, …)`, and it fires on the word inside a
string.

The boundary is therefore two checks, and they are **not** a complete input
ledger. `#line` is source *position* information: it records where emitted code
came from, so a file that contributes no code has no position to record, and its
absence says nothing about whether it was opened.

| check | catches |
|---|---|
| every producer stage runs with the **snapshot as its working directory** | a relative `require` of a file the snapshot lacks, including an empty one |
| the **`#line` scan** over the generated C | a require contributing code from outside the snapshot |

| spelling | refused by |
|---|---|
| top-level `require "json"` | the `#line` scan |
| `require_relative` of an **empty** file | the snapshot working directory — it leaves no `#line` at all, measured |
| `require_relative` of a comment-only file | the snapshot working directory |
| `x = 1; require "json"` | the envelope (the assignment) |
| `Kernel.require "json"` | the envelope (a receiver) |
| `require` inside an uncalled method | the `#line` scan |
| `MSG = "require me"` | **not** a dependency; refused for the assignment |

**Not closed:** a require resolved inside the compiler's own tree whose file
contributes no code is read, leaves no `#line`, and never touches the snapshot
working directory. Neither check sees it. The product path is **not** described
as closed against this, and closing it needs the producer to report what it
opened — proposed separately in
[input-ledger-proposal.md](input-ledger-proposal.md), deliberately not folded
into the approved seam.

The generated C is produced **once**, with line maps, and that same C is
compiled. Probing and then regenerating would read the dependencies a second
time and compile something the scan never examined.

### What the first version got wrong

| | |
|---|---|
| the snapshot | digesting the caller's file before and after cannot see a change that is reverted in between, and each stage re-read that mutable path. Every stage now reads a **copy**, and re-verifies each input it is about to consume against the manifest at the point of use. |
| the manifest | held the source and two tools. It now holds the checker, the contract reader, the runtime archive, the gate, both compilers, the target and the overflow mode. A source that `require`s another file is refused, because the snapshot cannot contain the dependency and a manifest covering part of a build describes none of it. |
| fail-closed | `sha256sum \| cut` and `nm -u \| wc` hide the leading command's failure in POSIX sh. A checksum tool that cannot run yields an empty digest that compares equal to another empty one, and a symbol reader that cannot run produces no symbols — which is what "no undefined dependencies" looks like. Every reader's exit is now checked before its output is read. |
| the compilation contract | the C was generated for the hosted default (`raise`) and compiled with `-DSP_INT_OVERFLOW_MODE_PROMOTE`, and `CC` defaulted to `cc` independently of `CLANG`. One `--int-overflow` now drives both the generation and the define, `CC` defaults to `CLANG`, and the two are refused if `-dumpmachine` disagrees. |
| publication | `mv` from `/tmp` is a copy and a delete across filesystems, which can leave a half-written file where a working one was. The staging area is now an exclusively created directory in the **output's own directory**, renamed within it: testing a name with `[ -e ]` and then writing is not exclusive, and `[ -e ]` does not see a dangling symlink. A directory as the output is refused, because `mv` onto one moves into it and succeeds. |
| the manifest's headers | the final compile reads headers from the seam checkout, which is mutable. They are now **copied into the snapshot** and compiled from there — digesting one set and reading another checks nothing — listed with `-print0`/`-0` because a path with a space breaks `ls \| xargs`, and `-MD` records which headers were actually included so every one can be checked. |
| digests | `printf '…' "$(digest …)"` makes printf's success the only status that survives, so a digest dying mid-manifest left an empty field and the build carried on. Every value is computed and checked before anything is written, and a checksum tool that fails once partway through is a negative control. |
| diagnostics | the checker's stderr was discarded and the first two lines of its report were dropped unconditionally. Both are now shown in full. |

### The gate is a program, not a predicate copied into a test

`tools/core/core-artifact-gate` asks the three questions, and the driver calls
it. The tests call the same program, so a gate that stopped working fails them
too — a test that re-implements the predicates checks its own copy, and a copy
that drifts is indistinguishable from a gate that broke.

Each of A, B and C is exercised by an object that violates exactly that one: an
extra core symbol, an undefined dependency, and a symbol exported as data with
no text. `NM=/bin/false` is refused as a reader failure rather than read as an
empty answer.

### Portability, stated rather than assumed

`sha256sum`, GNU `nm` and `-lcrypt` make the driver and the gate **Debian-only
today**. The macOS forms of all three — and the Mach-O form of A, B and C — are
separate work to be measured there, not inferred from here. Both scripts say so
in their headers, and the test suite prints it.

### The stages

`tools/core/spinel-core-build --source app.rb --core <method> -o app` is the
Extended driver. Per the reviewed split it owns the snapshot and target
manifest; the vendor seam only consumes a resolved identity, emits the mapping,
keeps the signature it inferred, and omits the body.

Six stages, each refusing rather than continuing, and none falling back to
another:

| | |
|---|---|
| 0 manifest | digest the source, both tools, the toolchain, the target and the selection; the digest is the snapshot id both halves carry |
| 1 eligible | the source admits the selected root |
| 2 hosted | C with the root declared and not defined, plus the mapping |
| 3 core | the object defining the mapped symbol |
| 4 artifact | A entries, B undefined, C the root has text |
| 5 link | the executable, moved into place last |

The source is digested before and after; a build spanning two versions of a file
describes neither. The executable is written to a temporary path and moved into
place only once it exists whole, so a failed build never replaces a working one.

The overflow mode is **fixed** at the hosted default, `raise`, and is not an
option. The checker and the emitter reach the source through the contract
reader while the hosted half reaches it through the compiler — two analyses that
agree today because both run at their defaults. Exposing a mode would let them
be given different ones, and the prototype check at the boundary is a check of
the *boundary*, not a substitute for the two analyses being the same. The
boundary control is kept by driving the seam compiler directly.

`tests/native-core/driver.sh`: **27 passed, 0 failed.**

### What is managed, and what is an environment assumption

Managed, digested and re-verified at the point of use: the source, the runtime
headers, the runtime archive, both tool binaries, the contract reader, the gate,
the target triple and the overflow mode.

Not managed, and not claimed: the system toolchain (`/usr`, `/opt/llvm-*`), the
SDK, and the C library headers they pull in. The include check permits exactly
those prefixes and refuses anything else, so the set is visible rather than
assumed — but this is **not** a hermetic build.

## Signed boundary values

| operand | result |
|---|---|
| `lower(9223372036854775807, 0)` | 0, agrees with CRuby |
| `lower(-9223372036854775807, 0)` | −9223372036854775807, agrees |
| `lower(-9223372036854775807, 9223372036854775807)` | −9223372036854775807, agrees |
| `lower(-9223372036854775808, 3)` | **refused** |

The last is the reserved minimum. The admitted domain is
`[INTPTR_MIN+1, INTPTR_MAX]` and the reason is the hosted printer, not the
parameter type — so the three boundary cases above must pass and this one must
not. It is refused for *types*, because a literal at the sentinel makes the
closure `bigint` before any domain rule sees it; the test asserts the refusal
rather than the reason, which keeps it a behaviour check.

## What this does not establish

- **Anything about macOS or Mach-O.** The symbol checks here are ELF.
- **Anything outside this fixture set.** Four programs of one shape.
- **A runtime-free executable.** The executable contains the hosted runtime by
  design; only the *core object* is checked for independence, and only at the
  object boundary.
- **Multiple roots.** The mapping and the emitter both accept several; no
  fixture uses more than one.
