# The lowering's inputs against Spinel's known pitfalls

Decision [0026](../decisions/0026-owning-the-core-lowering.md), step 3. For
each pitfall the decision names, this records what the lowering
(`tools/mlir/native/lib/Frontend/Scalar/`) reads, and whether the pitfall is
**not reached**, **reached and harmless** (with the reason), or a **defect**.
A defect gets its own fix branch; none is fixed here.

**Observed** means seen in the named source at `f19a94d`, or in the output of a
command given below and run on 2026-10-23 with the native build of this tree
and the reader built from it (both held to the tree by their source stamps).
**Inferred** means concluded from source without running it. The source
survey this starts from (the reviewer, `6e23735`) read sources only; its line
references were re-read at `f19a94d` and hold.

The probes ran in a scratch directory with a copy of
`tools/freestanding/spinel/freestanding.rb` under `spinel/`, as

```
spinel-fs-emit --profile tools/freestanding/profiles/cortex-m33-zephyr.yaml \
  --source FILE.rb -o x.o --emit-llvm x.ll --emit-header x.h \
  --emit-mlir FILE.mlir --typedump SPINEL_TYPEDUMP
```

for the freestanding route, and for the CORE route

```
spinel-core-kernel k.contract --root DIR --typedump SPINEL_TYPEDUMP \
  --clang /opt/llvm-23.1.1/bin/clang -o k.o --header k.h
```

with a version 1 contract naming the root, the entry and its `i64`
parameters.

## Summary

| pitfall | CORE (kernel, native core) | freestanding (fs-emit) |
|---|---|---|
| decisions only in Spinel's C codegen (callees, dispatch) | reached and harmless: the setup envelope refuses what would make them matter | **defect (ii)**: a reopened `Integer#+` is ignored |
| methods nothing calls | reached and harmless: refused, or typed from the contract | reached and harmless: a synthetic driver calls them |
| line shifts from `require` splicing | not reached: one file per root | lines are right; **defect (i)**: the file is the root's |
| renames (`__redefN`, `A__Ctx`) | reached and harmless: refused | reached and harmless: refused |
| nodes that span two files | not reached: one file per root | reached: a definition split across two files is accepted |

## 1. Decisions that exist only in Spinel's C codegen

Observed (source): the reader exposes the raw inferred types
(`tools/contract/spinel_contract.h:229-239`), not the hosted call plan. The
lowering resolves a receiverless name through the file's top-level
definitions (`Importer.cpp:95-149`) and lowers a receiver operator from a
closed set (`Importer.cpp:649-667`); it never asks which method Ruby would
dispatch to.

CORE, observed (command): a root that reopens `Integer` with its own `+`
beside `def f(x) x + 1 end` is refused,
`not-eligible: binding-environment: top level supports only definitions and
calls into the selected closure (…/reopen.rb:1:0)`. The setup envelope
(`Eligibility.cpp:2164-2285`) is what makes name and operator lowering valid
there. Inferred: this holds for the admitted subset only, not for arbitrary
Spinel input.

**Freestanding, defect (ii), reproduced.** The same file, with
`require_relative "spinel/freestanding"` and
`freestanding_def :f, params: [:i32], returns: :i32` above `def f`:

```ruby
require_relative "spinel/freestanding"
class Integer
  def +(o)
    42
  end
end
freestanding_def :f, params: [:i32], returns: :i32
def f(x)
  x + 1
end
```

Observed: spinel-fs-emit exits 0 (`wrote reopen.o`) and the MLIR lowers
`x + 1` to `spinel.checked_add %arg0, %c1_i32 policy trap`. The declaration
reader (`Declaration.cpp:99-124`) and the subset walk (`Importer.cpp:160-174`)
look at the declared methods only; nothing on this route refuses a top-level
reopening. Inferred: in Ruby, and in Spinel's hosted build, `f(1)` calls the
reopened `+` and answers 42, while the object answers 2. This was not run
against CRuby (an oracle).

**Fixed** in `5a1be0d` (branch `fix/fs-reopened-builtin`): the declaration
reader refuses a top-level `class`, `module` or `class <<` of Integer, Float,
Numeric, Comparable, Kernel, Object or BasicObject, and a top-level call that
changes one (`prepend`, `include`, `class_eval` and the like), as
`reopened-builtin`, naming the file, line and form. `tests/lowering/reopened.sh`
checks it, with the CORE control. Refinements are not covered.

## 2. Methods Spinel never lowers because nothing calls them

Observed (source): unchecked native CORE needs Spinel's own type evidence and
refuses an uncalled method with parameters (`parameter a is poly`,
`tests/core-eligibility/run.py:203-210`, read, not run). Checked contracts and
application entries take their parameter types from the contract
(`Eligibility.cpp:196-203`, `:2362-2365`; `Core/Kernel.cpp:263-267`), and the
selector uses those signatures (`Importer.cpp:441-495`). Freestanding
generates a driver that calls each declared method
(`Freestanding/Emit.cpp:1195-1205`) and imports from that second stage.

Reached and harmless on both routes: no route lowers a method from a type
Spinel did not infer or the contract did not state. Inferred: a hosted caller
must not be invented for unchecked CORE.

## 3. Line shifts from Spinel's own `require` splicing

Observed (source): the reader turns compiler builtins off before parsing
(`spinel_typedump.c:510-513`), so their splice does not move node lines.
Spinel's parser maps each line of the concatenated buffer back to its file and
line and stamps `node_line` and `node_file` (`vendor/spinel/src/spinel_parse.c:958-994`).
Eligibility uses `node_file` for its diagnostics (`Eligibility.cpp:70-80`).
The lowering does not: `locOf` (`MlirGen.cpp:809-814`) and each function's
location (`MlirGen.cpp:4130-4131`) use the root's file name,
`gen_.sourceFile()`, with the node's own line and column. Failure-site
records copy that location (`MlirGen.cpp:714-725`); importer diagnostics give
a line and no file (`Importer.cpp:256-272`).

CORE, observed (command): a contract root with `require_relative "helper"` is
refused before analysis, `cannot load such file --
/tmp/spinel-core-boundary-…/helper.rb`, `unanalysable-root`: the kernel analyses
a snapshot of the root file alone, and so, by its source, does the native
core driver (`tools/core/spinel-core-build`, step 0, copies the one file to
`input.rb`). Not reached, so no CORE failure site can
name the wrong file.

**Freestanding, defect (i), reproduced.** `helper.rb`, four comment or blank
lines and then

```ruby
def g(x)
  x * 3
end
```

at lines 5-7, and `main.rb`:

```ruby
require_relative "spinel/freestanding"
require_relative "helper"
freestanding_def :f, params: [:i32], returns: :i32
def f(x)
  g(x) + 1
end
```

Observed: exit 0. In `main.mlir`, `@sp_g` is at `loc("main.rb":5:0)` and its
`spinel.checked_mul` at `loc("main.rb":6:2)`; they are `helper.rb:5:0` and
`helper.rb:6:2`. The lines are the helper's own, so the source map works and
no line moved; the file name is wrong. Inferred: every location the lowering
gives a required file's node names the root, and so would a CORE failure site
if a multi-file root were ever admitted.

**Fixed** in `1055a01` (branch `fix/fs-loc-file`): the lowering takes each
node's file from its `node_file`, and the freestanding emitter maps its temp
copies back to the files they copy. `tests/lowering/locations.sh` checks the
fixture above: `g` at `helper.rb:5:0`, its `*` at `helper.rb:6:2`, `f` in
`main.rb`, no temp path.

## 4. Spinel's renames (`__redefN`, `A__Ctx`)

Observed (source): Spinel renames an earlier duplicate top-level definition
and its calls to `NAME__redefN` (`vendor/spinel/src/analyze.c:40592-40639`,
called at `:45055`) and qualifies colliding nested class names with `__`
(`analyze.c:3959`). The reader keeps the parsed spelling and publishes the
analysed scope names; the lowering names each function `sp_` and the selected
method's name (`MlirGen.cpp:4130-4134`), not hosted codegen's mapping.

Observed (command): two top-level `def g` and a declared `f` calling `g` are
refused by spinel-fs-emit, `spinel-mlirgen: unsupported: 'g'`: the importer's
duplicate check (`Importer.cpp:301-302`, category `duplicate-method`), which
the freestanding route prints without its category (its
`scalarDiag` in `Freestanding/Emit.cpp` drops every importer category; an
earlier version of this record named `Diagnostics.cpp:91`, which prints the
declaration reader's refusals instead), so the text does not say why. CORE
refuses duplicate and conditional definitions (`Eligibility.cpp:300-312`) and
needs a top-level, non-class binding (`:92-102`). Reached and harmless: no
renamed name reaches the lowering. Inferred: classes, reopenings and modules
would need an explicit identity contract before they could.

**Fixed** in `b136646` (branch `fix/duplicate-method-diag`): the line keeps the
generator's spelling and adds the reason after the name, `spinel-mlirgen:
unsupported: 'g' (duplicate-method: defined more than once at the top
level)`, so `tests/freestanding/e081`'s pattern for k6_name_collision still
matches. `tests/lowering/duplicate.sh` checks it.

## 5. Nodes that span two files

Observed (source): the parser stamps one `node_file` for a node's start; its
end coordinates (`spinel_parse.c:981-994`) carry no file. The reader checks
file references (`Contract/Reader.cpp:584-591`), not spans.

CORE: not reached, one file per root (section 3).

Freestanding, observed (command): `half.rb` holds `def g(x)` and `x * 3`
with no `end`; `span.rb` is

```ruby
require_relative "spinel/freestanding"
require_relative "half"
end
freestanding_def :f, params: [:i32], returns: :i32
def f(x)
  g(x)
end
```

spinel-fs-emit exits 0 and lowers `g`, at `loc("span.rb":1:0)`: the `end` on
`span.rb:3` closes the definition `half.rb` opened, because Spinel splices the
required file into one buffer before parsing. Inferred: Ruby parses each file
on its own and would refuse `half.rb` with a syntax error, so this route
accepts a program Ruby refuses. Not one of the two candidate defects; recorded
for the owner, with its location naming the root as in defect (i).

**Fixed** in `5016f44` (branch `fix/fs-split-def`): the freestanding emitter
parses each required file alone and refuses one that does not parse, as
`split-across-files`, naming the file and the parser's first error.
`tests/lowering/split.sh` checks both directions, with controls.

## 6. "A 32-bit target" read as the Integer width (observed in step 5)

Decision 0026 step 5 sorted the lowering's tests of `integerBits() == 32`
by the width each one means. Two say "target" and read the Integer width:

- `tools/mlir/native/lib/Frontend/Scalar/MlirGen.cpp:3236` at `c7affd5`
  (`:3234` after step 5): an i64 extern parameter is refused with
  `int-width-boundary: an i64 extern is refused on a 32-bit target; use i32`
  when `integerBits() == 32`;
- `MlirGen.cpp:3529` at `c7affd5` (`:3527` after step 5): an i64 extern
  return is refused with `... an i64 extern return is refused on a 32-bit
  target; use i32` under the same test.

Observed in the code, not run: a source that `tools/core/int64-allow.tsv`
lists has a 64-bit body on a 32-bit target, so neither refusal applies to it
there, although its words name the target. The table's own rows say this is
how E081 calls its i64 externs at 32 bits. Whether the check should read the
pointer width (now `ScalarImportOptions::pointerBits`) or the message should
name the body width is [0019](../decisions/0019-target-integer-width.md)'s
question for the owner; neither is changed here, because either change
changes what the route accepts or says.

**Fixed in `81496fd` (owner, 2026-10-24): the words now name the width the
test reads.** The test stays `integerBits() == 32`, so the routes accept
what they accepted; a listed source keeps its i64 externs at 32 bits, which a
test of the pointer width would refuse. The refusals now say
`an i64 extern is refused when Integer is 32 bits; use i32` and
`an i64 extern return is refused when Integer is 32 bits; use i32`.

Two refusals outside the lowering made the same claim under the same test,
and `387b0a5` changes their words in the same way:

- `tools/mlir/native/lib/Core/Boundary.cpp:869` refuses a kernel contract
  with an i64 result, parameter or extern when the Integer is 32 bits:
  `int-width-boundary: an i64 boundary is refused when Integer is 32 bits; use i32`;
- `tools/mlir/native/lib/Freestanding/Emit.cpp:1131` refuses a
  `freestanding_def` with an i64 parameter or result under the same test:
  `int-width-boundary: NAME has an i64 boundary, which a 32-bit Integer refuses; use i32`.

The refusal of an unlisted `# spinel: int64` body keeps "a 32-bit target":
the target's pointer width decides it.

## 7. The intrinsics' prelude in the reader's input (decision 0042 stage 4)

On `--core` and freestanding, a source that names a word intrinsic is read
with the prelude's definitions of the names it spells placed before the
program, after the source's leading blank and comment lines
(`tools/core/hosted-prelude.rb`, embedded in the native tools;
`Core/Prelude.h`), so that a call to one has a type in the analysis. Before
the program, because upstream Spinel from `1782a9e13` on gives a call that
runs before a method's first definition a `NoMethodError` arm, whose rows
the contract reader cannot resolve. The contract
reader drops the prelude's nodes again (`ContractInputs::preludeLine` and
`preludeLines`: the entry file's nodes on those lines, with their scopes,
locals and methods, but the program node and its statements node), moves
every later node of the entry file back to its own line, and the module's
file names are mapped back to the source, so no location, digest or closure
names the copy. The reader's own failure text, which names the copy, gets
the source's lines too. A UTF-8 byte order mark stays the copy's first
bytes; the parser counts it in line 1's columns, so a program that starts on
line 1 behind it gets those 3 columns back. A source that names no intrinsic
is read as it is.

- The copy is written to a temporary directory, or beside the source, under a
  unique `.spinel-prelude.` name, when the source spells `require_relative`:
  the parser resolves that load from the entry's own directory. That copy is
  removed on exit and on SIGINT and SIGTERM, and a directory it cannot be
  written to is refused with the words `not writable`
  (`tests/native-core/ledger.sh`).
- The entry file is the `FILE` row that `SOURCE_FILE` names. The root node is
  not: with a `require_relative`, the program node carries the required
  file's id.
- A top-level definition of a table name is refused on these routes wherever
  it is, called or not (`conflicting-intrinsic`), because the prelude would
  define the same name; the status lane keeps decision 0022's rule. The
  freestanding route prints this, and `unsupported-intrinsic-call` (a
  receiver, a block, a wrong argument shape, `core_u32` of anything but a
  literal in 0..4294967295, a 64-bit form on a 32-bit body), as
  `spinel-mlirgen: unsupported: ...` lines with the checkers' words.

## Not covered

- spinel-fs-grad includes the freestanding emitter (`spinel-fs-grad/main.cpp`
  includes `Freestanding/Emit.h`); whether it reaches the same selection and
  locations was not checked, and neither defect was probed through it.
- The 0014 applications take their entries from one packed file
  (`tools/doom/pack-core.rb`); they were not probed separately.
