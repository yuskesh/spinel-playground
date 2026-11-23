# spinel_facts dialect — P001 input contract v1 / additive v2

- Status: **settled (v2)** — the 609 inputs of P002 (E061, main 00b64f8) passed through producer M1–M3 and this contract. **The user decided to share it with other projects (2026-10-24)** — see "Sharing rules" below
- Sharing rules: (1) The canonical source (the authoritative copy that others copy from) is this file together with `SPINEL_MLIR_PATCHES.md` and `patches/` (on spinel-mlir's main). A project that uses them pins a commit, copies them, and records the repo, commit and path in its own provenance (spinel-mlir's files are not edited directly from another repo). (2) The contract carries only target-independent facts — decisions for BPF or any other target belong in the using side's passes and are not added to this dialect. (3) Missing facts are requested from the bpf-mlir coordinator (spinel-mlir's reviewer) as an additive version addendum — an incompatible change raises the version and is announced to both users. (4) The license is undecided (awaiting the user's decision) — it is decided at distribution time
- namespace: `spinel_facts`. Its registered names are kept separate from spinel-llvm's `spinel.checked_*`. This settles the open question from R004.
- Related: P001, R002, R003, R004. Planned hand-written fixture: `test/Inputs/xdpcount.spinel.mlir`.

Target-independent — it holds only the facts Spinel saw. BPF decisions (finding roots, SB diagnostics, lowering) live in spinel-mlir's passes. No IR of Ruby semantics is built.

## Versioning rules

version=1 is the original contract with no request. version=2 additively carries the origin of E007's external analysis-root requests. An incompatible change to required attributes, meaning, or the interpretation of IDs / locs / types raises the version. Adding an optional fact is allowed only when it does not change existing meaning and does not fill absent facts by guessing. Unknown versions / profiles are rejected. producer_revision is pinned separately from the contract version. The old experimental name spinel_bpf is not accepted as an alias.

## Boundary

The pristine / analyzed AST, inferred types and codegen evidence of the same Spinel run are emitted as registered generic ops. There is no join by JSON / position.
The initial AST is a table of ID references and does not pretend that mutable locals are SSA. Typed ebpf SSA is built only after a semantic pass has checked it.
Module attributes carry the `spinel_facts.` prefix. The attributes of the ops below have no prefix.

## Module attributes

| Required attribute | Type / meaning |
|---|---|
| version | I64Attr = 1 / 2, unknown versions are rejected |
| producer / producer_revision | StringAttr, handwritten or the real Spinel pin |
| profile | v1 is handwritten-v1 / spinel-codegen-v1, v2 is spinel-codegen-v2 |
| status | StringAttr: success / rejected |
| integer_bits / overflow | I64Attr / StringAttr, the producer's target width and actual overflow mode (raise / wrap / promote). Not the width of the mathematical Integer |
| refusal_checked / refusal_count | BoolAttr / I64Attr, success is true / 0, a check that was not run is not treated as success |

## Op table

Every op has no operands / results and uses the generic assembly. The order is source, splice (optional), table (pristine / analyzed), type, evidence, diagnostic. Within a table, IDs ascend; the order of child arrays is as in the original.

| op | Required attributes | Optional attributes / region |
|---|---|---|
| spinel_facts.source | file_id: i64, path: string, text: string | keeps the original bytes |
| spinel_facts.splice (optional — E014 / M3) | before_line: i64 (≥ 1), file_id: i64 (needs a preceding source), origin: string (set / io_buffer / enumerable / builtin_extra / enumerator), path: string | One require that Spinel added by itself (a line not in the user's file). Emitted only when there is an insertion, in the order of Spinel's buffer. It is a record of origin; the consumer does not use it to correct spans |
| spinel_facts.table | phase: string (pristine / analyzed), root_id: i64 | 1 region / 1 block, nodes only, no terminator needed |
| spinel_facts.node | id: i64, kind: string, strings / integers / refs / arrays: DictionaryAttr, file_id: i64, span: ArrayAttr<i64> | origin_id: i64 only when the origin is known, floats: DictionaryAttr<StringAttr> |
| spinel_facts.type | node_id: i64, phase: string (= analyzed), kind: string | nilable: bool (omitted when absent), value_type: TypeAttr, rbs / owner / signature: string, singleton / widened: bool |
| spinel_facts.evidence | node_id: i64, phase: string (= analyzed), kind: string | name / dispatch / callee: string, candidates: ArrayAttr<StringAttr>, inlined: bool |
| spinel_facts.diagnostic | severity / file / message: string, line / col: i64 | method / slot / param: string, node_id: i64 (only when there is a real ID) |

Values in integers are decimal StringAttr (the backend's notation is not rounded to i64), refs are I64Attr (a missing child is -1), arrays are ArrayAttr<I64Attr>, strings are StringAttr (byte length kept, NUL not dropped).
A source-backed Integer node in pristine also has the StringAttrs literal_text (the Ruby original) / literal_decimal (the exact mathematical value) / backend_decimal. bigval is also kept in strings. A synthetic node in analyzed may omit literal_text when the original text is absent. literal_decimal is the value obtained from bigval or I.value, and does not claim to equal another reading of the source. The semantic pass checks differences between the original and the backend.
span is [start_line, start_col0, end_line, end_col0], lines from 1, columns from 0, end-exclusive. Absent is the combination file_id=-1 / empty array / unknown loc. When present, the loc is file / line / col0+1, converted once by the producer.
span is in the coordinates of the original file. Even when Spinel added a require by itself (builtins and so on), the producer (M3) maps lines back to the original file from its record of insertions. The producer checks that each mapped line matches the original file and the parse buffer byte for byte; if a node sits on a line that does not match, it exits rc 1 with `MLIR M3 unrecoverable span … reason=<content|sugar|map_unavailable|unlocated_splice>` (no success artifact). The consumer does not shift lines again. A node that spans two files (the root ProgramNode / StatementsNode when another file's statements come before the entry file) cannot be expressed by a span in one original file, so it has no position (file_id=-1 / empty array / unknown loc, integers' node_end_line is "0").
A diagnostic's col keeps the original value (0 if Spinel's refusal supplies only 0). No false precision is added. type / evidence refer to analyzed IDs.
The scope of an ID is (module, phase). The same number in pristine and analyzed is not proof of the same syntax. Absent evidence / inlined / nilable is distinguished from empty / false. callee / candidates are target strings and do not mean instance IDs. Independent scope / class tables are not in the initial contract; only existing metadata such as owner.

### Analysis-only attributes of analyzed nodes (v2 additive, E076)

The producer may add the following optional attributes to analyzed nodes. The version stays v2. They are records of the analysis; when comparing the syntax shape of pristine and analyzed, only the keys listed on the analyzed side are excluded. The values do not certify syntactic identity, the real callee, the type, or a lowering choice.

| Place / key | Type / where it occurs / meaning |
|---|---|
| integers.enum_copy | decimal StringAttr. A clone reference recorded by the analysis for a call to a method with an Enumerable name. Can occur both in clones from builtin desugaring and in user methods. Optional; the consumer does not choose its dispatch by its presence or its target |

A one-sided addition of an attribute not in the list, or a change to an existing value, is still rejected loudly as a shape mismatch (SB001 in the BPF consumer). A key of the same name in another dictionary, such as strings.enum_copy, is not in this list. Comparisons and checks of refs/arrays/loc/type/evidence are not skipped. This addendum does not extend v1's attribute comparison rules.

## Types, roots, rejection

The mathematical `!spinel_facts.integer` is distinguished from `!spinel_facts.unknown` / `!spinel_facts.void` / `!spinel_facts.nil` / `!spinel_facts.bool`.
M3's unknown/void sentinels stand for the absence of a type that Go JSON omits, and typed checks of values/callees stop on them as Unknown (kept separate from identity checks of declarations/Defs).
The corresponding type record has value_type. object / container / poly keep kind and the RBS / owner facts and are not disguised as integer.
Finding roots and judging the target's context is done by the consumer pass; the transport does not turn a Ruby parameter's unknown into an inferred type.
status=rejected means a module with diagnostics only and a non-zero exit. No success .mlir / schema / maps / ELF is published. The consumer reads machine-readable diagnostic attributes and does not parse stderr back.
The verifier checks shape, IDs, references, phase and span / loc. Ruby semantics, the range of mathematical literals, and target-specific judgments about callee / dispatch are made by the consumer pass. Anything beyond its capability stops loudly.

## v2 — origin of target-independent analysis roots (E007)

`--analysis-root=METHOD:TYPE[,TYPE...]` is an opt-in request used together with `--emit-mlir=<path>`. From E013, repeating it handles 1–16 requests in the same run. The restrictions top-level / no receiver / fixed positionals stay. No source is appended and no synthetic call is made. With no request the output is v1, byte for byte unchanged; only with a request is it v2. The profile is also checked strictly against the pairs in the table above, and no new op is added.

v2 requires `spinel_facts.analysis_roots: ArrayAttr<DictionaryAttr>`. An empty one is rejected.

The array keeps the CLI's request order. The analysis itself does not depend on the order for the same set of roots. A repeated method name, with the same or a different type list, is rejected as usage rc2 / no module, with no dedup / last-wins. A 17th request is also a named usage rc2. If different requests resolve to the same real DefNode, it is rejected with rc1 rather than seeding it twice as different roots. All requests are parsed first, and each is reflected into the same fixed point's root/seed/census.

|status|Attributes of each dictionary|
|---|---|
|success|method:StringAttr, def_node_id:I64Attr, requested_arg_types/resolved_arg_types:ArrayAttr<StringAttr>|
|rejected|only method and requested_arg_types. def_node_id/resolved_arg_types omitted, no analyzed table|

A success ID refers only to an analyzed DefNode with no receiver. The generic importer checks the unique ID, the method name, the fixed positional signature/arity, the lengths of both arrays, and that resolved matches the real param's TypeOp.kind. There is no implicit identification with pristine IDs. rejected keeps every request including unresolved ones, and omits ID/resolved from every dict even if some were seeded. No fictitious IDs or guessed resolved values are made. A usage error is rc2 / no module; resolution failures and ordinary refusals are rc1 / diagnostic-only.

requested is the CLI's original text; resolved is the real param slot after the fixed point, projected to TypeOp.kind. Example: for requested `obj_BPF::XdpMd`, resolved is `obj_XdpMd`. The echo of a request is not evidence of a type. A nominal request resolves uniquely to a fully qualified class declaration in the original text, and is not inferred back from underscores in internal names. A pristine class-declaration path and an analyzed real ClassInfo are linked only when kind/source file/span match uniquely. This declaration-identity check is not reused as a positional join to fill absent callee/evidence.

Matching BPF declarations, comparing source/def/shape between pristine/analyzed, judging whether ctx fits, and SB/lowering are the consumer's responsibility. A fully qualified class identity is not inferred back from the short kind in resolved. Reflecting the existence of an external object in the census does not mean that the constructor's execution was observed.

## Honest boundary

Handwritten IDs / types / evidence are fixture assumptions and not evidence of a Spinel run. Full AST semantics, per-instance callees and removing the codegen traversal are outside the initial scope. integer_bits and overflow keep the producer's observation. The facts' --verify-only checks shape only and can also keep 32 bit / wrap as facts. E001's BPF consumer separately handles only 64 bit / raise and emits SB diagnostics.

## Optional typing-probe observation (v2 additive / M4 — E078)

Only with an explicit `--emit-mlir=<path> --analysis-root=... --emit-typing-probe` is a `spinel_facts.typing_probe` DictionaryAttr added to the module. Without the flag, v1/v2 are byte for byte unchanged. **Older facts without this attribute are also valid**; its absence means the observation was not supplied, not that there is no type without the injection. It is not permission for the consumer to guess the without-injection types or SB010.

| key | Type and meaning |
|---|---|
| version | i64, currently 1. spinel_facts.version itself is 2 |
| complete | bool true. Only when both the before and after real serializers completed. false/absent is not treated as an empty success |
| producer_patch | string `M4`. The provenance of the applied pin / M1–M4 SHAs / build / binary is also kept in an external pinned receipt |
| source_file_id / source_sha256 | ID of the real SourceOp / SHA256 of its text. Both analyses read the same source; differing before/after hashes are rejected |
| analysis_roots | {method, requested_arg_types} in request order. Equivalent to the requests in the existing module header |
| before_json / after_json | string. The real JSON of the existing `build_types_json`: before has no root seed, after has the requested seeds. An independent clean child analysis and the parent analysis. Types are not rebuilt by hand |
| before_stderr | string. before's real stderr. When before fails, the parent prints its cause to stderr and does not publish a complete success |

types/diagnostics/codegen of both JSONs are the original serializer's arrays; types keeps the TypeRec with file/line/col/kind/type/rbs and optional name/owner/signature/singleton/widened/end_line/end_col in the original order. Omitted end positions are also kept as the original observation. The meaning of the serializer omitting unknown/void is not changed, and absent records are not filled with fictitious unknowns. Empty types only when a complete table was actually observed. Required keys/types/JSON parse/each record/source hash/roots/completeness are checked by the validator in `scripts/lib/typing-probe.rb`.

This is **an observation of the analysis only**. SB010/acceptance and root/flow exceptions are not decided in the producer. Even if it contains the codegen array, it does not stand in for the current facts' callee/type evidence or for a successful source identity. The same ID or span in before/after is not identified with identity in the current pristine/analyzed; the existing gates of source/real structure/lexical membership stay. The span/kind comparison key for Go's CompareTypes is Go's specification, not a rule that allows a positional join of callees. There is no fallback that reconstructs the full text of SB010 without the metadata.

A signal / a partial analysis / missing JSON / a source mismatch / a transport or IO failure is not published as complete=true. Existing rc / diagnostics / atomic writer / rejection modules without the new flag are unchanged. Users pin M4's producer patch and the flag, and a spinel-extended at another pin needs a port of the corresponding patch. E078 is a transport test; full-text compatibility with Go's SB010 is checked by a later E's differential.

### Use on the consumer side in E079

E079 checks the source / requested roots / completeness of M4's JSON, and compares Go `CompareTypes`'s span/kind, name/RBS/signature and `paramReads` from pristine's structure. Only real type differences become SB010; acceptance is not decided by syntax alone (local / arithmetic / comparison). This JSON is not used for callee evidence or for generating SSA.

The success path that uses an embedded kernel struct (`[:struct, S]`) needs M4's observation. Without it, it stops with a named SB001 unsupported and no success artifact, and does not guess the without-injection types to make a success or SB010. The older 707 inputs without metadata are unchanged. For the calibration of 8 positives / 2 SB010 negatives, and the evidence of the absence controls including real Go SB010 sources, see E079.
