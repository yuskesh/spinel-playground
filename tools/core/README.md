# Core source eligibility

`spinel-core-check` checks one ordinary Ruby method and its statically reachable
direct callees. It reports supported core source constraints independently of
an exported ABI. It does not emit code or certify a hosted object as independent
of the Spinel runtime.

## Build and run

From the repository root, initialize and build the pinned compiler and its
contract reader as described in [Building and testing](../../docs/building.md).
Then build the native tools:

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 tools/mlir/native/build.sh
tools/mlir/native/build/bin/spinel-core-check app.rb --method pick
ruby tests/core-eligibility/run.rb
```

For example, `app.rb` can contain:

```ruby
def lower(a, b)
  a < b ? a : b
end

def pick(a, b)
  lower(a, b)
end

pick(7, 3)
```

The call in the source supplies ordinary inference evidence. The checker does
not run the program, insert synthetic callers, or assume types for an uncalled
method. This example produces two `CHECKED` rows and reports two checked methods.
It requires no `freestanding_def`, RBS file, target profile, FFI declaration or
foreign integer width.

`--typedump PATH` explicitly selects the contract reader. Otherwise the driver
searches executable ancestors for `tools/contract/build/spinel-typedump`. An
out-of-tree binary may need the explicit path. Use the reader built against the
pinned Spinel revision on the same host; arbitrary reader implementations are
not authenticated by this tool. The acceptance runner accepts
`SPINEL_CORE_BUILD` and `SPINEL_TYPEDUMP` for nondefault build locations.

## Exact initial rules

The check applies to the inferred source context and the host integer
representation of the reader/checker build. It does not promise eligibility for
other callers with different argument types.

| Operation or evidence | Rule |
|---|---|
| Entry and callee | One unconditional top-level definition with required positional integer parameters and integer return; AST, method and local identity must agree |
| Integer literal | Inferred integer representable by host `intptr_t`, excluding its reserved minimum/nil value |
| Local read/write | Known scalar type and matching method scope; no nullable integer or captured cell |
| Comparisons | `<`, `<=`, `>`, `>=`, `==`, `!=` on two proven integer operands, returning boolean; no allocation, promotion or failure operation is introduced |
| Conditionals | Predicate and both explicit branches must be supported; all branches are inspected, even if a sample input would not take them |
| Direct helper call | Exact argument count and inferred types; check the full reachable method body under these same rules |
| Arithmetic | `UNKNOWN`: overflow, nil and failure behavior is not proved, even for a small constant expression |
| Heap/state use | Known heap constructs, Ruby indexing, captured cells and global/instance/class/constant state are refused |
| Other operations | `UNKNOWN`, including recursion, blocks, unresolved calls, externs, unsupported nodes and missing evidence |

Booleans are allowed as intermediate comparison results, not as the initial
method parameter or return contract. The tool has no type, overflow, trap, wrap,
buffer or target flags. It never changes those properties to obtain admission.

The underlying hosted compiler emits primitive C comparisons for the admitted
integer comparison case. This supports the operation rule, but its surrounding
translation unit still contains runtime initialization: a `CHECKED` source
report is not an object-level independence claim.

Top-level execution is deliberately restricted too: only unconditional ordinary
method definitions and direct calls into the selected closure with integer
literal arguments are admitted. This includes the inference call in the example.
Other setup produces `UNKNOWN`, including assignments, printing, loading files,
and metaprogramming. Even `x = 1; pick(x)` is outside this initial input envelope.
Without this restriction, `Integer.prepend(Module.new { def <(x); false; end })`
could change comparison semantics before the selected method runs. Following
only the selected body, or forbidding a few mutation spellings, misses that case.

Unrelated allocating method bodies do not by themselves reject the selected
root; executing an unexamined setup method at top level does. The tool uses a
closed supported subset, not an allocator-name blacklist or an extern regex.

## Reports and errors

TSV columns are `verdict`, `method`, `location`, `reason`, `path`, and `detail`.
Tabs, newlines, control characters and percent signs inside cells are percent
encoded. Diagnostic positions retain source file, one-based line and the
producer's zero-based column. A helper violation includes a path such as
`pick -> lower`.

- `CHECKED`: the complete selected closure satisfies the supported source rules.
  These rows are printed only if the entire requested check succeeds.
- `REFUSED`: a known core constraint is violated.
- `UNKNOWN`: required evidence or an operation/binding rule is missing.

The summary counts discovered methods, checked methods, visited body nodes and
diagnostics. On a failure, checked-method count is zero; visited-node count is
not a claim of complete traversal of unsupported syntax. Exit codes are 0 for
complete admission, 1 for a refusal/unknown result, and 2 for usage, subprocess
or contract-reader failures. An empty report cannot pass.

The four reader faces are sealed by the existing strict contract reader. Source
changes detected between reads fail rather than mixing snapshots. A supplied
reader returning empty or malformed data also fails. Each reader subprocess has
a 30-second limit. The source is inspected, not sandboxed or executed by the
checker; the compiler's frontend still performs its normal input processing.

One pinned-producer limitation is recorded by the tests: a literal `send` can
leave a transformed node in the type face but not the AST. That case fails at
contract validation with `dangling-reference` (exit 2), before eligibility.

## Scope of verification

See [provenance](../../docs/provenance.md) for the host, toolchain and commands
actually exercised. This checker neither resumes the paused hosted-to-core
bridge nor completes the native core/full milestone. Exported objects still
need their own ABI, reachable dependency and artifact checks.

## Building a native executable

After the same pinned build, select a root without adding source declarations:

```sh
tools/core/spinel-core-build --source app.rb --core lower -o app.bin
./app.bin
```

The driver checks the source and input ledger, obtains the compiler's internal
symbol/signature mapping, emits the selected closure through MLIR, checks the
object and links the hosted executable. It supports the initial native scalar
slice on Debian x86_64 and macOS arm64. The executable includes the hosted
runtime; independence is checked on the core object. See
[reproduction and limits](../../docs/native-core/reproducing.md).

## The contract-file route

The decision 0007 boundary is a **separate** tool, `spinel-core-kernel`, not a
mode of `spinel-core-build`; the scalar route above is unchanged by it. It takes
a validated contract file instead of a source file and a method name, and emits
a CORE object and the C header a caller compiles against:

```sh
tools/mlir/native/build/bin/spinel-core-kernel app.contract --root . \
  -o app.o --header app.h --clang "$LLVM_PREFIX/bin/clang"
```

`spinel-core-boundary` validates a contract and generates the header alone,
`spinel-core-adapter` generates the Full-facing C and Ruby that call the object,
and `spinel-core-package` binds a build's artefacts together and verifies them.
The contract-file encoding, the checked arithmetic and buffer rules, the adapter
operations and worked usage are in
[the CORE buffer boundary](../../docs/core/buffer-boundary.md).
