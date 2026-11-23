# 0048: The project licence is Apache-2.0 WITH LLVM-exception

- Date: 2026-11-20
- Status: **Decided by the owner on 2026-11-20.** This record writes down
  the decision; the coordinator wrote it.

## Context

Until now the repository had no top-level licence. `docs/imports.tsv` marked
the files written here `original-pending`, and the files ported from the
owner's earlier repositories, which state no licence, `none-stated`. Both had
to be settled before the repository is published as spinel-playground
(the PG-H plan's step 7).

This project is a compiler. Code from this repository ends up inside the
programs it builds:

- the glue, runtime pieces and helpers that a core app, a freestanding image
  or a WASM module links;
- eBPF objects, whose license section says `"GPL"`: the C route writes
  `char LICENSE[] SEC("license") = "GPL";`
  (`tools/ebpf/src/spinel_ebpf/codegen_bpf.rb`);
- the DOOM board image, which links code compiled from the GPL-2.0 DOOM
  sources with glue generated from this repository's templates.

The bpf-mlir repositories that Extended imports or builds against (bpf-mlir,
go-bpf-mlir, spinel-bpf-mlir, bpf-mlir-loader) are Apache-2.0 WITH
LLVM-exception. GitHub's licence detection reports them as plain
"Apache-2.0", but their LICENSE files carry the LLVM Exceptions section. The
bpf-mlir coordinator confirmed this on 2026-11-20.

## Decision

1. The project licence is **Apache-2.0 WITH LLVM-exception**.
   - `LICENSE` is `tools/spinel-bpf-mlir/LICENSE` byte for byte, the text
     the owner's bpf-mlir repositories use.
   - `NOTICE` names the copyright holder and summarises the parts under
     other licences.
2. It covers the files written here. Their `imports.tsv` label is
   `project`, which replaces `original-pending`.
3. It also covers the files ported from the owner's earlier repositories,
   by the owner's statement of the same day. These are the 56 rows that
   THIRD_PARTY.md section 3 listed as stating no licence. Their label is
   `project-ported`, which replaces `none-stated`. A file in such a row
   that has its own `SPDX-License-Identifier` line keeps that licence;
   this is the rule the check already applied to `none-stated` rows.
4. Third-party files keep their own licences, with their texts beside them
   (THIRD_PARTY.md section 1), as before.
5. The files written here inside `examples/doom` are GPL-2.0. These are the
   two rows that were `original-pending` with the note "decide at
   publication". `examples/doom/NOTICE.md` already redistributes that tree
   under GPL-2.0, and these files derive from or drive its code (for
   example, `core/knot/enemy.rb` is derived from `lib/doom/enemy.rb`). The
   notices themselves stay `project`.

## Why the LLVM exception

- **Embedded portions.** When compiling puts parts of this software into a
  user's object, those parts can be redistributed without sections 4(a),
  4(b) and 4(d): no licence text and no NOTICE in the user's product.
- **GPLv2.** Where Apache-2.0 terms would conflict with GPLv2 in software
  combined with GPLv2 code, the licensee may waive them. Both the eBPF
  output and the DOOM board image combine with GPLv2 code.
- **The same licence as the bpf-mlir repositories**, whose code shares the
  eBPF route.

The alternatives considered were plain Apache-2.0, MIT (the licence of
upstream Spinel), and MIT OR Apache-2.0. The first two lack one or both of
the properties above. The owner chose Apache-2.0 WITH LLVM-exception over
all three.

## Consequences

- `tools/provenance/check-imports.rb` and `tools/provenance/third-party.rb`
  use the new labels. THIRD_PARTY.md now states the project licence, and
  its section 3 lists the ported files that licence covers.
- `tests/imports/run.sh` plants the new labels.
- The export manifest's rewrite of `docs/imports.tsv` deletes the export
  tool's row under its new label, and its pins are renewed.
- `docs/provenance.md` records the decision at the top. The earlier
  sections that said the licence was undecided are kept as records of
  their time.
