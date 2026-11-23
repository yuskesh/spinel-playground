# Proposal: have the producer report the files it opened

A minimal vendor addition, **proposed only**. Nothing is implemented, no seam
change is made, and this is deliberately not folded into the approved
`--core` seam.

## What was not closed before this

The driver's dependency boundary used to be two heuristics, and together they
were not an input ledger.

| check | catches | measured |
|---|---|---|
| every producer stage runs with the **snapshot as its working directory** | a relative `require` of a file the snapshot does not contain, *including an empty one* | `require_relative "empty"` is refused: `cannot load such file` |
| the **`#line` scan** over the generated C | a require that contributes code from outside the snapshot | a `require "json"` names `json.rb` in a `#line` directive |

What neither sees: **a require resolved inside the compiler's own tree whose
file contributes no code.** An empty or comment-only package file is read, emits
no `#line` directive, and resolves without touching the snapshot working
directory. Measured for the relative case — `require_relative` of an empty file
produces no `#line` entry at all — and the same reasoning applies to a packaged
one.

`#line` is **source position information, not an input ledger**. It records
where emitted code came from. A file that contributes no emitted code has no
position to record, so its absence from the directives says nothing about
whether it was opened. The two checks above are what can be built without the
producer's help; they are not equivalent to knowing what it read.

So: the product path is **not** closed against this case, and is not described
as closed anywhere. The driver refuses everything it can see.

## Why the eligibility checker cannot close it either

`require` never reaches the checker. Measured: the frontend consumes it before
the contract is written, and the ast face for a program with a top-level
`require "json"` is identical to one without — same node count, no `require`
node. A structural check would have to run *before* the frontend strips them,
which is inside the producer.

## Implemented

Approved and implemented on `yuskesh/spinel` branch `core/input-ledger` at
`74aa36d8`, branched from `00218233`. It is **not** on the approved
`core/selected-root-seam` branch: it is a separate change, reviewed on its own.

`--inputs-out=<path>` on the hosted compiler, `--inputs-out` on the contract
reader, the core checker and the core emitter. Nothing is written without the
flag, and the flag changes nothing else.

### Where it is recorded

`read_file` in `src/spinel_parse.c` — the one function every load goes through:
the root, every `require`, and the requires inside those. Paths are recorded
**resolved**, because a relative path in a ledger is not a record of anything:
reading it back would need to know the working directory each stage ran in.

### The format

One record is a path followed by a single **NUL** byte. NUL because a path may
contain a newline, which a line-oriented file cannot represent unambiguously.
Readers split on NUL and nothing else; `read -d` is a bashism, so the shell side
uses `xargs -0`.

### Fail closed

| condition | result |
|---|---|
| a recording failure (allocation, or a path that will not resolve) | the write fails rather than producing a short ledger |
| an **empty** ledger | an error — the frontend cannot have produced anything without reading the root, and a caller comparing an empty set against the snapshot would find nothing outside it |
| a write failure | the partial file is removed, exit non-zero |
| a ledger missing the source the stage was given | refused — it does not describe that run |
| any recorded path outside the snapshot | refused |

The ledger is written **before** the `-S` and `-c` early returns, which leave by
different doors; written past one of them it would be missing exactly when a
caller asked for C and wanted to know what produced it.

### Each analysis accounts for its own inputs

The driver asks the eligibility checker, the hosted compiler and the core
emitter separately. A ledger from one run does not describe another, so a single
hosted probe is not accepted as the reader's input list.

### What it records that the heuristics could not

An empty required file, a comment-only one, a constants-only one, a `require`
inside a required file, a packaged `require`, and a path containing a space —
each measured, each now refused by the driver.

The `#line` scan is **gone** from the driver. It was never an input ledger, and
nothing falls back to it.

## Environment assumptions, stated

The driver manages: the source, the runtime headers (copied into the snapshot
and compiled from there), the runtime archive, the compiler and emitter
binaries, the contract reader, the gate, the target triple and the overflow
mode. Each is digested and re-verified at the point of use.

It does **not** manage, and does not claim to: the system toolchain (`/usr`,
`/opt/llvm-*`), the SDK, or the C library headers those pull in. The include
check permits exactly those prefixes and refuses anything else, so the set is
visible rather than assumed, but their contents are an environment assumption
and this is not a hermetic build.
