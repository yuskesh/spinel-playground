# Task 2: binding and the internal call contract, measured

Decision [0005](../decisions/0005-native-core-executable.md), plan task 2. Every
statement here was measured against the pinned compiler
(`vendor/spinel` `5bc45ec19a372c6f4da29485a7ce35c81b9751cc`) on Debian with
LLVM/Clang 23.1.1, and is reproducible with `tests/native-core/task2-probe.sh`.

**This is Linux/ELF evidence.** Nothing here is evidence about macOS or Mach-O;
task 1 is the other side's. Where the two must agree, the agreement has to be
measured there, not inferred from here.

## 1. The prototype the producer actually emits

For the acceptance program, unmodified:

```ruby
def lower(a, b)
  a < b ? a : b
end

puts lower(7, 3)
```

the pinned compiler emits

```c
static inline __attribute__((always_inline)) sp_int sp_lower(sp_int lv_a, sp_int lv_b);
...
{ sp_int _t1 = sp_lower(7LL, 3LL); if (_t1 == SP_INT_NIL) putchar('\n'); else printf("%lld\n", (long long)_t1); }
```

So inference already produces the narrow machine-width signature this slice
wants. Two properties of it are the whole problem:

- **No `sp_lower` symbol was produced, measured.** `static inline
  __attribute__((always_inline))` is not in general a guarantee that no symbol
  exists -- an inline function can still be emitted out of line, and taking its
  address forces that. The claim here is only what was measured: compiling this
  program's generated C with this compiler at `-O0`, `-O1`, `-O2` and `-Os`
  yields **0** `sp_lower` symbols of any binding (no `T`, no `t`), and the
  linked binary the driver itself produces has 0 as well. So for this program a
  core object has nothing to define and the hosted call site has nothing to
  call. A program that took the method's address, or a different compiler or
  flag set, has not been measured and is not covered by this statement.
- The name is `sp_lower`: `sp_` + the method name, for a top-level `def`.

Both are decided in one place, `vendor/spinel/src/codegen.c:2273`
`emit_method_signature`, at the storage and inline-hint lines (`:2277`, `:2289`).

## 2. `--ext-entry` already produces the right prototype

The existing external-call support is not a boxing boundary by construction. The
same method as a module singleton, **with an integer call site in the program**:

| emission | prototype |
|---|---|
| ordinary hosted | `static inline __attribute__((always_inline)) sp_int sp_M_s_lower(sp_int, sp_int)` |
| `--ext-entry M.lower` | `sp_int sp_M_s_lower(sp_int lv_a, sp_int lv_b)` |
| `--ext-entry M.lower`, **no** call site in the program | `sp_RbVal sp_M_s_lower(sp_RbVal, sp_RbVal)` |

The `sp_RbVal` in the third row is the **absence of a caller to infer from**, not
something `--ext-entry` imposes. `emit_method_signature` reads `s->ret` and the
inferred parameter types either way; `is_ext_entry` only clears `static` and the
inline forcing.

This matters for the plan's "compare a narrow hosted codegen seam with existing
external-call support, choose by binding fidelity": on binding fidelity they are
the *same* mechanism. The existing path already keeps the proven non-nullable
integer domain. It loses nothing, because there is nothing between the caller
and the callee to lose it.

## 3. The reserved value: measured, and worse than the header claims

`lib/sp_types.h:98` documents `SP_INT_NIL == INTPTR_MIN` as reserved by the
`int?` (nullable) type, and says a plain non-nullable `int` holding it "is fine,
since it never consults `sp_int_is_nil`", INT64_MIN being "effectively
unreachable in practice" on 64-bit.

Measured, both halves of that are wrong for this slice:

- **The consumer tests it unconditionally.** `puts` on any `int` operand emits
  `if (_t1 == SP_INT_NIL) putchar('\n'); else printf(...)`, including for a plain
  local `x = 5`. The check is at the *consumption* site and does not ask whether
  the value is nullable.
- **INTPTR_MIN is reachable in a plain `sp_int`.** In the default overflow mode,
  `v - 1` where `v` came from `ARGV[0].to_i` as `-9223372036854775807`:

  | | output |
  |---|---|
  | CRuby | `-9223372036854775808` |
  | pinned Spinel, hosted | *(empty line)* |

  One producer is closed: `String#to_i` refuses `-9223372036854775808` outright
  with `RangeError: integer overflow parsing` (`lib/sp_core.c:62`), because it
  accumulates the magnitude positively. That is why an earlier probe of mine
  looked like a nil misprint and was not one; the arithmetic route above is the
  one that actually reaches it.

**Consequence for the boundary.** The admitted value domain of the first slice is
`[INTPTR_MIN + 1, INTPTR_MAX]`, and the reason is the hosted *consumer*, not the
parameter type. A core implementation that returns `INTPTR_MIN` would be printed
as nil by the acceptance program itself. This is the "test the minimum reserved
hosted value separately from valid limits" checkpoint, and its answer is that the
full i64 domain is **not** available even for a proven non-nullable integer.

The hosted `puts` behaviour above is a pre-existing defect of the pinned base
revision, independent of this work. It is reported, not fixed here.

## 4. A hand-built connection probe -- NOT the product path

**What this is and is not.** Sections 1 and 3 are about the ordinary top-level
`def lower` of the acceptance program. This section is a *separate*, hand-built
probe that used a **module singleton** (`M.lower` -> `sp_M_s_lower`) and
**hand-edited C**. It establishes that the linkage shape works. It is **not**
evidence that the product's CLI-selected top-level connection works, and nothing
in it was produced by a `--core` path, because none exists.

Every manual step, in order, so the gap is visible:

1. Wrote `extm2.rb`: `module M; def self.lower(a, b); a < b ? a : b; end; end`
   with `puts M.lower(7, 3)`. The method was **moved into a module** because
   this probe needed a name the rest of the step could work with; the acceptance
   program's top-level `def` was not used here.
2. Ran the pinned compiler with `--no-line-map -S` to get the ordinary hosted C.
3. **Edited that C with a script**: replaced the one
   `static inline __attribute__((always_inline)) sp_int sp_M_s_lower(...)`
   forward declaration with a plain external declaration, and deleted the
   function definition's text from `{` to the matching `}`.
4. Hand-wrote a separate C file defining `sp_M_s_lower` with `typedef long`
   parameters, compiled it alone with no Spinel headers or runtime.
5. Compiled the edited C and linked it with that object and `libspinel_rt.a`.

Steps 3 and 4 are exactly what a real implementation must **not** do: the plan
forbids growing a generated-C rewriter, and the internal signature must come
from the producer's own mapping rather than a hand-written `long`. They are
acceptable in a throwaway probe whose only claim is about linkage.

With that stated, the probe's result:

| core object | result |
|---|---|
| correct body | prints `3` |
| deliberately wrong body (`return 999`) | prints `999` |
| body absent | link refused, `undefined reference to 'sp_M_s_lower'` |

The `999` is the routing proof the plan asks for: the hosted source body is gone,
not shadowed, and there is no fallback. The absent case fails the build rather
than quietly reverting. The core object has **0 undefined symbols** and defines
exactly `sp_M_s_lower`.

The internal interface used by that object was `long` — the machine-width
interface **for this target**, internal, not a stable public `i64` API, exactly as
decision 0005 requires it be described.

## 4b. Two closures, and proving `INTPTR_MIN` cannot arrive

Section 3 shows that "the parameter is a non-nullable `int`" does **not** prove
the value is inside the admitted domain: the measurement that reached the
sentinel went through an ordinary non-nullable `sp_int`. So the domain has to be
proved per value, and the first thing that needs fixing is *where* the values
come from.

### The two sets are different

- **H, the admitted hosted envelope.** The part of the hosted program eligibility
  admits: top-level statements, setup, and the hosted methods among them. `puts
  lower(7, 3)` lives here.
- **C, the core callee closure.** The selected root(s) plus the helpers
  statically resolved from them, lowered into the core object.

An earlier draft of this section said a parameter's domain is the union over
"every call site inside the checked closure". That is wrong, and wrong in the
direction that matters: the checked closure is normally the root and below, so
**the caller of the root is not in it**. For the acceptance program the only
call to `lower` is in H, and a rule quantified over C alone quantifies over an
empty set and proves nothing.

### Ingress, enumerated

An **ingress** is any call into a member of C from anywhere. Two kinds:

- **root ingress** -- a call from H to a selected root;
- **helper ingress** -- a call from outside C to a helper inside C.

The rule is an *enumeration* requirement, not a per-site test: the producer's
resolved call graph must account for **every** call to every member of C across
the whole program. If any call to a member of C cannot be attributed to a
specific admitted call site with a computed argument domain, the build is
refused. An unaccounted caller is a refusal even if every accounted caller
proves fine.

This is not hypothetical. Measured, in a program whose top level is

```ruby
puts lower(7, 3)
puts outer(9)
```

with `def outer(x); lower(x, 3); end`, the producer emits `return sp_lower(lv_x,
3LL);` inside `sp_outer` as well as the top-level call. If `lower` were the
selected root, that is a second ingress, and its domain comes from `outer`'s
parameter, which comes from `outer(9)`. A rule that looked only at the top-level
statement would compute `{7, 3}` and miss it.

Two further measurements on how ingress must be *found*: in these programs the
pinned producer statically resolved both `send(:lower, 9, 2)` and
`method(:lower)` + `m.call(9, 2)` into ordinary direct `sp_lower(...)` calls. So
the source spelling is not the discriminator, and neither is a scan for direct
calls in the generated C. The rule consumes the **producer's resolved call
graph** and refuses whatever the producer could not attribute. Nothing here
generalises to "`send` always resolves"; that was measured in these programs
only, and a `send` the producer cannot resolve is exactly an unaccounted caller.

### The value rules

Every rule yields a domain or `UNKNOWN`; `UNKNOWN` anywhere in C, or any
unaccounted ingress, refuses the build. No runtime guard, check or trap is added
by any of this -- every decision is made before emission.

| # | form | domain |
|---|---|---|
| D1 | integer literal `L` | `{L}` **if** an explicit range check passes, else `UNKNOWN` |
| D2 | parameter of a method in C | union of the argument domains over **all enumerated ingresses and all intra-C call sites**, provided the ingress enumeration is complete |
| D3 | comparison `a < b` | not an integer producer (boolean) |
| D4 | `cond ? x : y` | `domain(x) ∪ domain(y)` |
| D5 | local read `x` | the domain bound to `x` (D6) |
| D6 | local assignment `x = e` | binds `domain(e)`; a local assigned at more than one point takes the union of those domains, and is `UNKNOWN` if any of them is |
| D7 | direct call to a member of C | that method's return domain |
| D8 | a method in C reachable from itself | `UNKNOWN` -- recursion is refused, not analysed |
| D9 | **anything else** | `UNKNOWN` |

**D1 is an explicit check, not an inference from observed behaviour.** An
earlier draft argued "by construction" from two measured literals. Two examples
do not establish a compiler-wide invariant, and the invariant would be about the
*target's* width in any case. So D1 range-checks each literal against
`[INTPTR_MIN + 1, INTPTR_MAX]` **for the configured target width**, and refuses
otherwise. The measurement below remains supporting evidence that the producer
also moves such literals off `sp_int`, and is not relied on:

| literal | emitted type |
|---|---|
| `9223372036854775807` | `sp_int sp_f(sp_int)` |
| `-9223372036854775807` | `sp_int sp_f(sp_int)` |
| `-9223372036854775808` | `sp_Bigint * sp_f(sp_Bigint *)` |

**D8** keeps recursion out rather than adding a fixpoint analysis; D2 and D7 are
then a walk over a call graph with no cycles among admitted members.

**D9** is load-bearing, and the two measured sentinel routes land in it.
Arithmetic is `UNKNOWN` -- not only because decision 0005 defers it, but because
it is the route that actually produced `INTPTR_MIN` in a plain `sp_int` (§3).
Any runtime input (`ARGV`, `gets`, `String#to_i`, ...) is `UNKNOWN` because
nothing in the source bounds it; note that `to_i` happens to refuse the sentinel
with `RangeError`, but that is one producer's behaviour, not a property of
runtime input, and D9 does not lean on it. Nullable, boxed, `Float`, `String`
and unknown-typed sites are `UNKNOWN` by the same rule, which is how decision
0005's "reject nil, floats, strings, unknown and incompatible call sites at
build time" is met.

### The acceptance program under these rules

```
C = { lower }                       H = { top level }
ingress enumeration: every call to lower in the program
  1. top-level  lower(7, 3)         root ingress, admitted
  (no others)                       enumeration complete
  a  <- D2 over ingress 1 -> D1 {7}   (7 in range)
  b  <- D2 over ingress 1 -> D1 {3}   (3 in range)
  a < b   D3   condition, not a value
  a : b   D4   {7} ∪ {3} = {7, 3}
  return  {7, 3} ⊆ [INTPTR_MIN+1, INTPTR_MAX]
```

Admitted. Change the call to `lower(ARGV[0].to_i, 3)` and D2 takes an `UNKNOWN`
argument from its only ingress, so the parameter is `UNKNOWN` and the build is
refused rather than run with a guard. Add `puts outer(9)` as above and the
enumeration must find the second ingress or refuse.

This rule set deliberately does not admit a *useful* program. It admits literals
and what comparison, selection and local binding derive from them. Widening it
is the arithmetic contract, a separate decision.

## 4c. Symbol identity and the mapping

Section 6's checkpoint 2 is that a top-level `def` cannot simply be given
external linkage. The existing guard, measured live:

| source | emitted C name |
|---|---|
| `def lower` | `sp_lower` |
| `def alloc` | `sp_rb_alloc` |
| `def arena` | `sp_rb_arena` |
| `def gc` | `sp_rb_gc` |
| `def str` | `sp_rb_str` |

`mc_top` (`src/codegen_util.c:1859`) compares the first `_`-delimited segment of
the mangled name against 224 prefixes generated from the runtime sources
(`build/csrc/sp_rt_names.h`) and rewrites to `rb_<name>` on a hit, and does the
same when a class or module owns the name. That guard exists for `static`
linkage. External linkage adds collisions it was never asked about: against
other translation units, and against the core object itself.

So the proposal is a **dedicated namespace**, not a storage-class flip:

```
spc_<snapshot-id>_<method-id>
```

- `spc_` is free: 0 of the 224 reserved prefixes is `spc`, and
  `libspinel_rt.a` defines 0 symbols beginning `spc_` (measured).
- `<method-id>` comes from the same inputs `emit_method_cname` uses -- the
  scope's `class_id`, `is_cmethod` and `name` -- **never** from the generated
  text. Decision 0005's "generated text is not a second authority for method
  identity" is met by construction.
- `<snapshot-id>` is a digest over the snapshot described next.

### The snapshot is the check; the symbol is not

An earlier draft said a build-identity digest in the symbol makes "a change
between stages invalidates the build" mechanical. It does not. A digest embedded
in a name only proves that two artifacts were *labelled* the same. If every
stage is handed the same stale mapping, they all agree with each other and the
link succeeds while the source on disk has moved on. The symbol cannot detect
its own staleness.

So the freshness guarantee is a **snapshot manifest**, and the symbol digest is
defence in depth behind it:

1. **One manifest, written once**, at the start of a build: the content digest
   of every source and dependency file the analysis reads, the compiler
   revision, the flags, the target triple and data layout, and the selected root
   set. The manifest's own digest is `<snapshot-id>`.
2. **Every stage reads that same manifest** -- eligibility, hosted codegen, core
   lowering, artifact checks, link -- by path, and each stage **re-digests the
   inputs it actually opens** and compares them against the manifest. A file
   whose content no longer matches is a refusal, naming the file. This is what
   catches a stale mapping: the mapping agrees with itself, but the source does
   not agree with the manifest.
3. **Every stage records the `<snapshot-id>` it used**, and packaging refuses
   unless all stages report the identical one. Mixed snapshots, mixed targets
   and mixed flag sets are refused here, by comparison, rather than being left
   to whether the linker happens to complain.
4. **The symbol digest is the last line, not the first.** A declaration and a
   definition carrying different `<snapshot-id>`s do not link, and the undefined
   symbol names both. That is a useful backstop for a case the checks above
   missed; it is not the freshness check and is not described as one.

### One mapping, three consumers

The mapping is emitted once, machine-readable, and the hosted **declaration**,
the hosted **call site** and the **MLIR/core definition** are all generated from
it. None of the three re-derives a name, and none parses C.

Collision is proved **from the producer's identifier and symbol mapping**, not
from how many times a string appears in the generated C. Counting occurrences in
the C is not a proof of anything: the same text can appear in a string literal
or a comment, and a collision can exist between two identifiers that never
appear adjacent. The checks, each a build failure:

1. **Injective over method identities.** Two distinct method identities must not
   map to one symbol.
2. **Disjoint from the producer's other identifiers.** The selected symbols must
   not collide with any name in the producer's own emitted identifier table, nor
   with the runtime name set that `mc_top` already consults. Compared as sets of
   identifiers, from the producer, not by searching the output text.

### Artifact checks: three separate questions

An earlier draft required the core object's defined-symbol set to equal the
mapping's expected set exactly. That is wrong twice over: it forbids things a
correct object legitimately has, and it is not even stable across optimisation
levels. Measured on a correct core object with one local helper and one
referenced table:

| | `-O0` | `-O2` |
|---|---|---|
| `T spc_demo_lower` | present | present |
| `t clamp_lo` (local helper) | present | folded away |
| `r table` (referenced data) | present | folded away |

An exact match over *all* defined symbols would have failed this object at
`-O0`, and passed the same source at `-O2`. So the questions are separated:

- **A. Entry set.** The **externally visible defined** symbols of the core
  object, restricted to the core namespace, must equal the mapping's expected
  entry set exactly. Local symbols, section symbols and platform metadata
  symbols are outside this check and are not constrained by it.
- **B. Undefined dependencies.** The core object's undefined-symbol set must be
  empty for this slice. A separate measurement, and the check decision 0005
  means by "no external core dependencies" -- not a symbol-prefix allowance.
- **C. Reachable code and data.** The selected closure's code and the data it
  references are actually present in the object. Separate again, and not
  inferable from A or B: the table above shows a referenced constant may be
  folded into instructions and carry no symbol at all.

On macOS these must be asked with Mach-O-aware tools and Mach-O's own notion of
external visibility. The ELF measurements above do not answer them for that
target.

## 5. The vendor change: exact scope, for review only

`--core` is a **new product path**. It does not reuse `--ext-entry`'s CLI, which
is a library mode: it refuses a top-level `def` ("spell it Module.method"), it
pairs with `--ext-init`, and it emits a library rather than a hosted executable.
What is reused is only the **shared type and signature generation** -- the part
that turns an inferred scope into a C prototype -- because §2 measured that this
is already the right prototype.

Concretely, the proposed diff. Nothing below has been applied; `vendor/spinel`
is untouched and the pin has not moved.

**1. A selection input, not a mode.** A new compiler-side list of selected root
method identities, populated by the driver from `--core <method>`. It does not
imply library mode, `--ext-init`, or `-c`.

**2. `src/codegen.c:2273` `emit_method_signature`, two existing lines.**

- `:2277` storage: today
  `((g_debug && s->class_id >= 0) || s->is_ext_entry) ? "" : "static "`.
  Add "or this scope is a selected core root" to the external-linkage side.
- `:2289` inline hint: today `s->is_ext_entry ? "" : method_inline_force(...)`.
  Same addition, so a selected root is not force-inlined.

  These are the two lines §1 identified, and `is_ext_entry` already proves the
  shape works. Neither line touches types: `emit_ctype(c, s->ret, b)` and the
  parameter loop are untouched, which is what keeps the inferred narrow
  signature and adds no ABI.

**3. `emit_method_cname` / `mc_top`: a namespace, not a rename.** A selected
root's C name comes from the §4c mapping (`spc_<build-id>_<method-id>`) rather
than from `sp_` + `mc_top`. The existing `mc_top` behaviour for every
non-selected method is unchanged; the measured `sp_rb_alloc` rewrites keep
working exactly as they do today.

**4. Body omission.** At the definition site, a selected root emits its
declaration and no body. This is the one genuinely new behaviour, and it is what
makes a missing core object a link failure rather than a silent hosted fallback
(§4).

**5. The mapping and the snapshot manifest as outputs.** The compiler writes the
§4c mapping so the core side consumes identities rather than re-deriving them
from C, and writes the snapshot manifest every stage re-verifies its own inputs
against.

Not in scope, and not authorised by this proposal: any change to inference, to
`emit_ctype`, to the overflow modes, to `sp_int`/`SP_INT_NIL`, to the runtime,
or to the arena and default paths. No boxing, no trap insertion, no exception
conversion, no i32 narrowing, no new ABI.

Compatibility checks the change would have to carry, before any pin move:
default and arena corpus gates unchanged; `make test` unchanged; the generated C
for every program with **no** `--core` selection byte-identical to the current
pin (the same check §4 of the arena work used); and the `mc_top` rewrites above
re-measured.

## 6. Open contract checkpoints — these need a decision before implementation

1. **The admitted domain excludes `INTPTR_MIN`** (§3), proved per value by the
   rules in §4b rather than asserted from the type. Confirm: the split between
   the hosted envelope H and the core closure C; the ingress **enumeration**
   requirement (every call to every member of C attributed, or refuse); D1 as an
   explicit target-width range check rather than an inference; the local
   binding rules D5/D6; recursion refused as `UNKNOWN` (D8) rather than analysed;
   and that a core body producing `INTPTR_MIN` is out of contract rather than a
   bug to fix here.
2. **Symbol identity and freshness.** Proposal in §4c: the
   `spc_<snapshot-id>_<method-id>` namespace; a **snapshot manifest** that every
   stage re-verifies its own inputs against, which is the freshness check, with
   the symbol digest as defence in depth behind it rather than the guarantee;
   collision proved from the producer's identifier mapping rather than by
   counting occurrences in the C; and the artifact questions separated into
   entry set (externally visible only), undefined dependencies, and reachable
   code/data. Confirm the namespace and the manifest's inputs.
3. **`--core` is a new product path** (§5), reusing only the shared type and
   signature generation, not `--ext-entry`'s library CLI. Confirm.
4. **Vendor change approval.** §5 is the exact scope, five items, unapplied.
   `vendor/spinel` is untouched and the pin has not moved. No approval is
   assumed from the review of this report.

## 7. Not established here

- Anything about macOS, Mach-O, the SDK, or arm64. Task 1.
- Arithmetic of any kind inside a core body. Deferred by decision 0005, and §3
  shows why its overflow contract is a prerequisite rather than a detail.
- Any call site that is not a proved non-nullable integer. Floats, strings, nil
  and unknown call sites are to be refused at build time; the refusal itself is
  not implemented yet.
- Multiple roots, helper closures deeper than a direct call, and method identity
  across a source change. Tasks 3–5.
