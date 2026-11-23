# otlp-agent -- kept as files: an oracle

Ported from spinel-llvm `463d49dd` (P013 Task 9, E156 checkpoint 2) and not run
here. It reads the spbpf schema JSON and raw record bytes, and it builds a
normalized OTLP data model with the Go standard library only. By its design, it
is the Go leg of E156's three-way differential (the Spinel C backend, the
Spinel MLIR backend and this program). It is an independent reimplementation
whose job is to check the others. That makes it an oracle, and in this
repository an oracle runs only on the owner's instruction.

Usage, as spinel-llvm documented it:

```sh
otlp-agent -schema schema.json -records records.bin \
           -record <core.records[].symbol> -wall-offset-ns <ns>
```

spinel-llvm's Japanese README is replaced by this note.
