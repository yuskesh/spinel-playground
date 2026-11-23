# Proposed vendor diff for `--core`

Decision [0005](../decisions/0005-native-core-executable.md); the checkpoint
promised after [the task 2 report](task2-binding-report.md) `§5`, reflecting the
three corrections in `bddd6f6`.

**Status: proposed, not applied.** At the time of this proposal,
`vendor/spinel` was unmodified at `5bc45ec19a372c6f4da29485a7ce35c81b9751cc`
and the pin had not moved. This
document is the reviewable shape of the change; it is not a request to treat the
review of it as approval.

Every line number is against that pin.

## Why any vendor change at all

Measured (task 2 report `§1`, `§2`): the producer already infers the exact
signature this slice needs, `sp_int sp_lower(sp_int, sp_int)`. Two properties
stop a core object from providing that body, and both are decided in one
function:

- it is emitted `static inline __attribute__((always_inline))`, and no
  `sp_lower` symbol of any binding was produced at `-O0`, `-O1`, `-O2` or `-Os`;
- a top-level `def` is named `sp_<name>` via `mc_top`, which is deliberately a
  `static`-linkage name.

`is_ext_entry` already flips the first of those, which is why the change is
narrow rather than novel: the shape is proven, it is the *selection* and the
*naming* that are new.

## The five items

### 1. A selection input, not a mode

A compiler-side list of selected root **method identities**, populated by the
driver from `--core <method>`.

It is deliberately not a mode: it does not imply `--ext-init`, does not imply
`-c`, does not switch to library emission, and does not change what any
non-selected method does. `--core` is a new product path and does not reuse
`--ext-entry`'s CLI, which refuses a top-level `def` and emits a library.

### 2. `src/codegen.c:2273` `emit_method_signature` — two existing lines

```c
/* :2277 today */
const char *stor = ((g_debug && s->class_id >= 0) || s->is_ext_entry) ? "" : "static ";

/* :2289 today */
const char *ihint = s->is_ext_entry ? ""
                  : method_inline_force(c, s) ? "inline __attribute__((always_inline)) "
                  : (method_inline_hint(c, s) ? "inline " : "");
```

Both gain "or this scope is a selected core root" on the `is_ext_entry` side.
Nothing else in the function changes: `emit_ctype(c, s->ret, b)` and the
parameter loop are untouched, which is what keeps the inferred narrow signature
and adds no ABI.

### 3. `emit_method_cname` — a namespace for selected roots only

A selected root's C name comes from the mapping (`§4c` of the task 2 report),
`spc_<snapshot-id>_<method-id>`, instead of `sp_` + `mc_top(...)`.

`mc_top`'s behaviour for every non-selected method is unchanged. That is a
requirement, not a hope: it is what keeps `def alloc` emitting `sp_rb_alloc`,
measured live today for `alloc`, `arena`, `gc` and `str`.

### 4. Body omission — the one genuinely new behaviour

A selected root emits its declaration and no body. This is what makes a missing
or mismatched core object a **link failure** rather than a silent hosted
fallback, which the hand-built probe demonstrated (`§4`: absent body → refused
link; wrong body → `999`, proving the call routes to the core object).

### 5. One new output: the symbol mapping

**the mapping** — resolved method identity → symbol, consumed by the hosted
declaration, the hosted call site and the core definition, so none of the three
re-derives a name or parses C.

### Where the manifest lives, and why not here

The **snapshot and target manifest** is the Extended driver's responsibility,
not the vendor's. The driver already owns what the manifest describes: which
source it handed to which stage, the flags, the target, and the selected roots.
Putting it behind the vendor seam would make the pinned compiler responsible for
a build-orchestration fact it does not otherwise know, and would need a pin move
every time the orchestration changed.

So the vendor seam is limited to four things:

1. the **resolved selection identity** it is given,
2. the **symbol mapping** it emits for it,
3. the **signature** it already infers,
4. **body omission** for the selected roots.

Everything about snapshot freshness, target identity and stage agreement stays
in the Extended driver, which reads the manifest, re-digests each stage's actual
inputs against it, and refuses mixed snapshots, targets or flag sets.

## Out of scope, and not authorised by this proposal

No change to inference, to `emit_ctype`, to the overflow modes, to `sp_int` or
`SP_INT_NIL`, to the runtime, or to the arena and default paths. No boxing, no
trap insertion, no exception conversion, no i32 narrowing. Nothing here widens
the admitted value domain, which stays as `§4b` defines it.

### "No new ABI" means no new *public numeric* ABI

That phrase has been used loosely in earlier reports and is narrowed here. What
is true: no public numeric interface is added, no width or signedness contract
is exposed to a user, and nothing in the source gains a foreign-interface
declaration.

What is **not** true, and is recorded rather than glossed: this change creates a
**new internal linkage contract**. Before it, a selected method had no symbol at
all; after it, a hosted translation unit and a separately produced object agree
on a symbol name, a parameter list, a return type and a calling convention for
the configured target. That is an interface, even though it is internal,
unstable, and regenerated per build. It is the thing the mapping names, the
thing the snapshot manifest binds to a build, and the thing an artifact check has
to verify. Describing it as "no new ABI" without this paragraph would understate
what is being introduced.

## Compatibility checks the change must carry, before any pin move

1. **The generated C for every program with no `--core` selection is
   byte-identical to the current pin.** The whole upstream corpus, the check the
   arena work already used (3543 cases, `--no-line-map -S`).
2. `make test` unchanged: 3543 pass, 0 fail, 0 error.
3. The default and arena corpus gates unchanged against their declaration.
4. The `mc_top` rewrites re-measured: `alloc`, `arena`, `gc`, `str` still
   `sp_rb_*`, `lower` still `sp_lower` when not selected.
5. The runtime archives byte-identical, both configurations.

Checks 1 and 5 are the ones that make "the default configuration is unchanged" a
measurement rather than a claim, and they are the same two that caught a real
regression during the arena work.

## What is still blocking implementation

The four checkpoints in the task 2 report `§6` are unanswered, and item 4 of
them is approval for this diff. Task 1's measured target triple, data layout,
deployment target and SDK are also needed before `§5`'s manifest has real
contents for the macOS target, and the artifact checks A/B/C need their Mach-O
answers.
