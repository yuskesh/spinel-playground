# Contributing

The native `core` / `full` base exists. The immediate goal is to port what `spinel-llvm` and `spinel-ebpf` already achieved onto it, quickly.

## Development workflow

1. Read the architecture and milestone acceptance criteria.
2. Define the behavior being introduced and the existing contracts it must preserve.
3. Develop the change on a focused branch or worktree when isolation is useful.
4. Include the implementation, necessary fixtures, meaningful checks, and current documentation in the same reviewable change.
5. Run the relevant checks and record their results and limits in the pull request.
6. Integrate only when the capability is usable at its stated scope.

Implementation language, source directory layout, the public CLI, and the dependency installation workflow will be selected with the initial design. Existing precursor choices are evidence, not automatic requirements.

## Importing existing work

Port a working predecessor capability in one piece: a whole subsystem, backend or example is fine. The predecessor's behaviour is the specification, and its tests, fixtures and oracles come with it as the acceptance evidence. A port needs no design decision beforehand. Each import batch records:

- Its source repository, revision, and original paths.
- Relevant copyright notices and license terms.
- Changes made during the import.
- Required dependencies and fixtures.
- A reproduction command that works without the original checkout.
- Known differences from the reference implementation.

Extract essential fixtures from historical experiment directories into `tests/fixtures/` with provenance when needed. Keep large logs and exploratory material outside the maintained product tree. Oracle checks (against CRuby, a reference build or another implementation's output) are ported as files but run only when the owner instructs, and no new oracle is built without that instruction.

## Tests and evidence

Test accepted programs, rejected programs, and the boundary between generated components. For the first milestone, output equality alone is insufficient: checks must also detect forbidden allocation/runtime dependencies and invalid ABI crossings.

Keep compiler validation separate from platform execution evidence. A successful object emission does not prove successful linking or execution. Unsupported environments and skipped tests must be reported explicitly.

No compiler checks exist yet. Working build and test entrypoints are deliverables of the first implementation.

## Documentation and review

Write maintained documentation in English. Explain current behavior before historical context. User-visible behavior and ABI changes require a design decision; routine refactoring does not require a new decision document.

A pull request should describe the concrete behavior, validation performed, and material limitations. Preserve useful attribution without including private paths, session links, credentials, or personal environment details.

## Public release preparation

The project license is Apache-2.0 WITH LLVM-exception (LICENSE); contributions are made under it, as its section 5 says. Before a release, review imported-code compatibility and notices (`ruby tools/provenance/check-imports.rb`, THIRD_PARTY.md) and verify a clean checkout using only documented dependencies. Publish only intended branches and artifacts. A private working branch is not a substitute for secret handling: never commit credentials.
