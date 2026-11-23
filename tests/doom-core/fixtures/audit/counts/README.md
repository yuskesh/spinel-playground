# Three bindings, one line apart

`tests/doom-core/audit.sh` uses these to check that a `fixed:` count is only
evaluated when the binding it reads is shown to reach it. The three files are
identical except for the body of `init_bank`, which is why the suite declares
and checks the diff at two lines.

| file | `init_bank` binds | the array is | the audit must |
|---|---|---|---|
| `plain.rb` | `n = 64` | 64 long | evaluate it, and agree |
| `update.rb` | `n = 64` then `n += 1` | 65 long | refuse: two binders |
| `guarded.rb` | `n = 64 if false` | not built — `TypeError` | refuse: the binding may not run |

What each one really does is measured by the suite with `ruby` before anything
about the audit is asserted, so the premise is not taken on trust: 64, 65, and
`no implicit conversion from nil to integer`.

Both refusals matter and they are different. `update.rb` is the case where
counting **plain writes** answers 64 — there is exactly one
`LocalVariableWriteNode` and the update is a `LocalVariableOperatorWriteNode`,
of which DOOM's tree has 460. `guarded.rb` is the case where counting
**binders** answers 64 as well: there is exactly one binder and it still never
runs. The second is why the rule needs the binding to be unconditional and not
merely unique.

`counts.tsv` is the catalog these are audited against: one row, `Game#init_bank`
with the expression `n`, declared `fixed:64`.

# Two constants, one line apart

The same question for a constant, where "the only definition of that name in
the tree" is not a conservative answer but an unsound one.

| file | `init_bank` reads | CRuby says | the audit must |
|---|---|---|---|
| `scope-bare.rb` | `N`, defined in `Doom::Other` | `uninitialized constant Doom::Game::N` | refuse: not in scope |
| `scope-qualified.rb` | `Other::N` | 64 | evaluate it, and agree |

The definition in `scope-bare.rb` is unique in the tree, unconditional, and
earlier than the read. It is still not the constant that read names. Uniqueness
is evidence that a definition EXISTS; it is not evidence that a read reaches
it. The `nodes` face does not settle it either — that read is a
`ConstantReadNode` with `detail=N`, typed `int`, and neither the bare spelling
nor the type is a lookup.

All three scope fixtures put `include Math` in `Game`, and that line is
load-bearing. Since upstream e4eca9c84 the analysis replaces a bare constant
CRuby's lookup cannot reach with `(raise NameError, ...; nil)`, in place, so
`scope-bare.rb`'s `N` no longer reached the audit as a constant read, and the
audit now refuses a parse whose two faces disagree on a node's kind. The
upstream pass leaves a reference alone when the class has a builtin ancestor
with constants of its own, which `Math` is. CRuby's answers are unchanged:
`Math` has no `N` and no `Other`, so the bare read still raises NameError, the
qualified one still gives 64, and the shadow still raises TypeError. If the
analysis learns to follow `Math`, the bare fixture is rewritten again, and
the audit refuses it by `kind-mismatch` rather than reading it wrongly.

`counts-bare.tsv` and `counts-qualified.tsv` are their catalogs, one row each,
because the two fixtures allocate from different expressions (`N` against
`Other::N`) and a row matching no allocation is refused as a dead row.

`scope-shadow.rb` is `scope-qualified.rb` with `Other = 1` added inside
`Game`, and it shares `counts-qualified.tsv` because it allocates from the
same expression. CRuby answers `TypeError: 1 is not a class/module`: the inner
constant HIDES the outer module, and Ruby raises rather than looking further
out. A resolver that searches only for scopes walks straight past the `1` and
finds `Doom::Other`, which is how this read was being confirmed as 64. The
innermost binding of a name decides even when it is the wrong kind of thing.
