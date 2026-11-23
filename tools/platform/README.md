# tools/platform — the capability ledger and its checker

Which platform supplies which capability, what tier each capability needs, and
the checks that hold a program to them at build time. Ported from spinel-llvm
`463d49dd` (its P008 phases 1 and 3: E090, E093); see
[provenance](../../docs/provenance.md).

| File | What it is |
|---|---|
| `menus.yaml` | **The ledger.** For each platform: the capabilities it supplies, each capability's required tier, and its arch menu, with the pre-T5 profile that carries each (platform, arch) pair's target facts. Widening what a platform supplies means editing this file and nothing else. The freestanding emitter reads it to expand platform-first profiles. |
| `spinel-capcheck` | The checker (Ruby). `check` verifies tier and menu inclusion for an entry program; `spinel-wasm` calls it when a program has a profile, a require root or a tier comment. `profile` resolves a profile for shell callers. `tier` reports an entry's declared tier. A refusal exits 1, and its first line is `spinel-capcheck: REJECT <kind>: <detail>`; a usage error exits 2. |
| `spinel_platform.rb` | The shared reader: loading the ledger, both profile forms, the tier comment window, the two set-inclusion checks, and the one place the refusal format is written. |
| `arena.yaml` | The arena ledger: the names with GC semantics, and the escape policy for each resident scope, each with its reason. It applies only to `# spinel-tier: arena`, which needs spinel-llvm's vendor Patch 6; `spinel-wasm` refuses that tier on the pinned vendor. |
| `profiles/` | Full-tier profiles for the edge platforms: `workers-full.yaml` and `fastly-full.yaml`. |
| `ab/` | The checker's case table (`e168_cases.tsv`) and its fixtures, plus spinel-llvm's golden runner (see below). |

The set of capabilities a program requires comes from
`spinel-typedump <entry> features <vocabulary...> [-I dir]`. These are the
program's resolved requires, spelled as written and followed transitively,
with no grepping of source. Requires outside the reserved prefixes (`edge/`,
`cloudflare/`, `fastly/`) are not asked about.

## Checks

`tests/edge/capcheck_rc.rb` runs each of the 46 cases in `ab/e168_cases.tsv`
and requires the exit code the table declares: 0 to accept, 1 to refuse, 2 for
a usage error.

`ab/run_e168.sh` and `ab/test_e168.rb` compare the checker's full output byte
for byte with goldens recorded from spinel-llvm's retired Python
implementation. That is a comparison with another implementation's recorded
output, which makes it an oracle. They are kept as files and run only when the
user asks, and the goldens they read were not imported.
