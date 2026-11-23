# tools/contract — reading the pinned compiler's analysis in process

`spinel-typedump` links the vendor compiler's own objects and reads its
analysis results directly, instead of parsing what the `spinel` command line
prints. The core slice uses it as its front end: `spinel-fs-emit` runs it to
learn a program's structure, inferred types and method signatures.

## Files

- `spinel_contract.h` — the whole dependency on vendor internals, in one
  header: struct fields, functions, type constants and three parser field
  names. Nothing else in this repository reaches into `vendor/spinel`.
- `spinel_typedump.c` — the reader, written against that header only.
- `build.sh` — an external build. It links the objects `vendor/spinel`'s own
  build already produced, minus `main.o`, plus `libprism.a`. It writes nothing
  under `vendor/` and does not touch its Makefile.

## Build and use

```sh
make -C vendor/spinel deps      # the vendor objects need Prism and RBS first
tools/contract/build.sh         # -> tools/contract/build/spinel-typedump
```

```sh
tools/contract/build/spinel-typedump app.rb methods   # method table and ABI verdict
tools/contract/build/spinel-typedump app.rb locals    # local slot types
tools/contract/build/spinel-typedump app.rb nodes     # typed AST by node id
tools/contract/build/spinel-typedump app.rb ast       # re-serialised parse
```

`--int-width=32` or `--int-width=64` selects the pinned parser's target
Integer width before parsing and analysis. Without it the host width remains
the default. The reader stays a native host executable; no 32-bit build is
needed. `ruby tests/contract/int-width.rb` checks both literal boundaries.

Other modes exist and are used by tooling that this repository has not imported.

## Why a header rather than a text interface

Joining `--dump-ast` to `--emit-types` by source position is ambiguous: one
`(line, col)` routinely carries several nodes, and the types dump drops the node
id that would disambiguate them. Reading `ntype[id]` in process removes the
ambiguity, and also distinguishes "this node's type is not int" from "this node
has no inferred type", which the text dump cannot express.

It also localises upstream drift. A renamed or removed field is a compile error
in this one header rather than a silent misread somewhere downstream. The
header's tables record what each field is assumed to mean, which is the part a
compiler cannot check.

## Notice

`spinel_contract.h` reproduces two functions that are `static` in the pinned
Spinel tree, `ty_tag_into` and `emit_file_path` from `src/codegen.c`, so that a
dump can be compared byte for byte with the compiler's own. Spinel's MIT licence
and copyright, Yukihiro Matsumoto, apply to those parts. Their origin is marked
in the header. See [provenance](../../docs/provenance.md).
