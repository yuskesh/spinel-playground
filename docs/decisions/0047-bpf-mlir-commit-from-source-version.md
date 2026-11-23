# 0047: The bpf-mlir commit comes from SOURCE_VERSION, in a release and in a clone

- Date: 2026-11-16
- Status: **Accepted by the owner on 2026-11-16** (merge). The bpf-mlir coordinator asked for
  this rule after PG4's stop 3 (2026-11-16); reviewed by the bpf-mlir coordinator and
  the reviewer.

## Context

Two places in this repository read which bpf-mlir commit a source directory
holds:

- `tools/spinel-mlir/CMakeLists.txt` writes it into the consumer's
  `BuildRevision.h` as `SPINEL_BPF_MLIR_COMMIT`;
- `tests/spinel-bpf-mlir/run.sh` (`bpf_mlir_commit`) compares it with the
  `third_party/PINS` row before the suite runs.

Both took `git rev-parse HEAD` in a git checkout and read `SOURCE_VERSION`
(`format=1`, one `source_commit=<40 hex>`) only without git. The suite also
refused a checkout whose HEAD and SOURCE_VERSION disagreed, with a planted
control (`both`) that expected the refusal (P4-H, decision B).

The public bpf-mlir repository has its own history. A release tag points at a
release commit whose `SOURCE_VERSION` names the development commit the
release was made from; that development commit is not in the public history.
For v1.21.0, the PINS commit:

| | |
| --- | --- |
| tag v1.21.0 | commit `e5e439a0359611677e14205d1c3ec459a2737c77`, tree `2d7443c3c062bb053687232a316aa6e73137ed16` |
| its SOURCE_VERSION | `format=1`, `version=1.21.0`, `source_commit=41b188568cb36a15d4c185d5f72027267b3fa544` |

So a user who clones public bpf-mlir with git got a consumer header naming the
release commit, while bpf-mlir's own `ebpf-compile --version` (a distribution
build, which reads SOURCE_VERSION) named the source commit; and the suite
refused every such clone, because its HEAD is never the source commit. PG4's
stop 3 showed the first: the header said the release commit, the check
expected the source commit.

## Decision

One rule, in one place: `tools/spinel-mlir/bpf-mlir-commit.cmake`. The
consumer's CMakeLists includes it; it also runs as a script
(`cmake -DBPF_MLIR_SOURCE=DIR -P ...`, printing `commit <40 hex>`).
`tests/spinel-bpf-mlir/run.sh` reads a directory the same way in shell, and
its controls require both to agree.

1. **SOURCE_VERSION present: its `source_commit`.** This covers a source
   release (no git) and a clone of a public release. SOURCE_VERSION must have
   one `format=1` line and one `source_commit=<40 lowercase hex>` line, with
   LF line ends: a carriage return anywhere is refused (the review:
   CMake's `file(STRINGS)` drops it, so the two readers disagreed on a
   CRLF file).
2. **In a git checkout with SOURCE_VERSION, a guard**, so a checkout cannot
   claim a commit it does not hold:
   - SOURCE_VERSION must be tracked;
   - SOURCE_VERSION must be unchanged against HEAD;
   - the work tree must have no tracked change against HEAD (untracked files,
     such as a build directory, are allowed).
   Each failure stops with its own message.
3. **No SOURCE_VERSION, a git checkout: `git rev-parse HEAD`**, as before.
4. **Neither: refused**, as before.

## Changed expectations in the suite's source-commit controls

| control | before | now | why |
| --- | --- | --- | --- |
| release | read at the pin | same | |
| other | read as another commit | same | |
| none | refused | same | |
| both | refused (HEAD differs from SOURCE_VERSION) | read at the pin (SOURCE_VERSION tracked, clean) | the old expectation refused every clone of a public release, the main public path |
| checkout | (none) | a checkout without SOURCE_VERSION is read at its HEAD | rule 3 had no control |
| dirty | (none) | refused | rule 2's work-tree guard |
| edited | (none) | refused | rule 2's unchanged-against-HEAD guard |
| untracked | (none) | refused | rule 2's tracked guard: an untracked SOURCE_VERSION dropped into a checkout must not name its commit |
| crlf | (none) | refused | rule 1's LF line ends: both readers refuse a carriage return (the CMake reader used to drop it and read the file) |

The count is 9 (10 with `BPF_MLIR_RELEASE`), so P4's N4 now expects
`source-commit controls: 9 of 9`. Each control is read by both readers;
a disagreement fails the control and names both answers.

## The Go reader, a named difference

`tools/spinel-bpf-mlir/internal/toolchain/toolchain.go` (`releaseSource`) reads
`third_party/bpf-mlir/SOURCE_VERSION` in spinel-bpf-mlir's own public shape. It
already prefers SOURCE_VERSION, and it differs from this rule in two ways,
left as they are here:

- it **refuses** a checkout without SOURCE_VERSION, where rule 3 reads HEAD:
  spinelbpf compares `ebpf-compile --version`, which in a distribution build
  names the source commit, so a HEAD read could never match it;
- it does not check whether the checkout is dirty or SOURCE_VERSION is
  changed against HEAD (rule 2). It does check SOURCE_VERSION's exact three
  lines and its version.

That file is imported from spinel-bpf-mlir; a guard there belongs upstream
first.

## Consequences

- The PG4 run takes the public v1.21.0 clone with its `.git`, and the
  consumer header, `ebpf-compile` and the suite all name `41b18856`.
- `tools/dist/P4-H.md`'s decision B ("a checkout whose SOURCE_VERSION
  disagrees is refused") is superseded by this record.
