# 0020: Oracles run only with ALLOW_ORACLE=1, as tests/ORACLES.tsv lists them

- Date: 2026-10-19
- Status: Accepted (owner, 2026-10-19). The classification below is the owner's (2026-10-18/19, 2026-10-24).
- Scope: every check in `tests/` and `tools/` that compares with another
  implementation's behaviour, and the bundled runners that reach one.

## Context

AGENTS.md runs an oracle only on the user's instruction. An oracle is any check
against another implementation's behaviour: CRuby, a reference C build,
doomgeneric, a JAX or IREE reference, the replay of a recorded run against
CRuby, or a byte comparison with another implementation's recorded output.

The rule was kept by reading each script before running it, and that failed
four times. In each case the comparison sat inside a runner that was started
for its other lanes:

- `tests/core-boundary/run.sh`;
- the byte section of `tests/app/channel.sh`, reached from `tests/app/run.sh`;
- `tests/app/verify.sh` and the verify CLI's CRuby replay.

## Options

- **Keep the rule as a reading discipline.** This is the state that failed.
- **Move oracles out of the runners into separate scripts.** This changes
  the ported tests, and a port's tests are its acceptance evidence.
- **Gate each oracle section in place and keep a tracked list that a check
  holds to the tree.** The comparisons stay as ported. Only their entrances
  change.

## Decision

The third option.

**The switch.** An oracle section runs only when `ALLOW_ORACLE=1` is in the
environment. Without it the section prints the line below and is skipped:

```text
NOT RUN (oracle): <path> <section>: <what it compares with>
```

The skip is not a failure, and the section's checks are not counted. A
bundled runner therefore runs no oracle unless the switch reaches it.

**The gate.**

- Each section asks `tools/oracle/gate <path> <section>` in sh, or
  `OracleGate.allow?(path, section)` from `tools/oracle/gate.rb` in Ruby.
- The gate answers yes only when `ALLOW_ORACLE=1` is set and the list names
  `<path> <section>` as a gated row.
- A section the list does not name is refused even with `ALLOW_ORACLE=1`, so
  the list cannot be bypassed.
- A file gated as a whole uses the section name `whole` and exits 0 at its
  top.
- Checks that do not depend on an oracle's output still run past a gate. A
  lane skips only what reads what the other implementation produced.

**The list.** `tests/ORACLES.tsv` has one row per oracle section and one per
file that looks like an oracle and is not. Its columns are path, section,
class and what the section compares with. The classes are:

| class | meaning | gated |
|---|---|---|
| `owner` | the owner named it an oracle | yes |
| `definition` | it fits AGENTS.md's definition | yes |
| `confirm` | whether it is an oracle is the owner's call, not yet made | yes |
| `program` | a comparison program, run only from a gated section | no gate of its own |
| `exempt` | it mentions CRuby, an oracle or a replay and is not one: the owner ruled so, the comparison stays within one implementation, or the word names something else | no |
| `ungated` | an oracle this mechanism does not gate; the row says why and who starts it | no |

**The check.** `tests/oracle/check.sh` fails on any of these:

- a malformed row;
- a gate call without its gated row, or a gated row without its call, where
  each call must name its own file;
- a file that the oracle patterns find and that has no row;
- a file that names a `program` row and is neither gated nor a program. A
  program's row may name one file that mentions it only to exclude it.

`tests/oracle/run.sh` runs the check on the tree and on an identity copy. It
then plants one defect of each kind and requires each to fail with its own
message, and it exercises the gate in sh and in Ruby.

**Within one implementation.** A comparison between two paths of one
implementation, or between its old and new build, is not an oracle. The owner
made one exception (2026-10-19): a build by `BASELINE_KERNEL`, a kernel built
without the change, compared with the current one, is an oracle.

**The owner's classification.**

- **2026-10-18/19, not oracles, run routinely:**
  - `tests/doom-core`: `screens`, `native`, `native-scenario-diff`, `state`,
    `tick` and `verify`;
  - `tests/app`: `host` and `board`.
- **2026-10-19, oracles (class `owner`):**
  - the `baseline-kernel` comparisons of `tests/core-report/run.sh`,
    `tests/doom-core/loop-reports.sh` and `tests/app/doom-admission.sh`;
  - `tools/doom/use-probe.rb`;
  - `run_gpu_bridge.sh`, `run_otlp_semantic_oracle.sh` and
    `run_otlp_kernel_e2e.sh` under `tools/ebpf/tests/runtime/`;
  - the `otlp-semantic` step of `tools/ebpf/tools/spbpf_product_gate.sh`;
  - `cruby_m001_server.rb` and `cruby_m003_server.rb` under
    `tools/ebpf/benchmarks/targets/`.
- **2026-10-19, not oracles (class `exempt`):**
  - `tests/doom/compare-controls.sh`, `gate-r007-controls.sh` and
    `build-reference-controls.sh`;
  - the OTLP comparator's tests, which `tests/ebpf/run.sh` runs.

  The comparators these run on synthetic input (`compare.rb`,
  `gate-r007-golden.rb`, `make-fixture.rb`, `otlp_semantic_oracle.rb` and
  `otlp_oracle_test.rb`) are exempt rows for the same reason.
  `tools/doom/build-reference.sh` stays gated, but its gate moved to the
  doomgeneric build itself, so the refusals its controls check run without
  the switch.
- **2026-10-24, not oracles, run routinely:** the sixteen OTLP harnesses under
  `tools/ebpf/tests/runtime/` that decode what a sender wrote with protoc.
  protoc is a reader of the format, and they compare with no other
  implementation's output. Ten start a mock receiver (`run_otlp_send`,
  `_grpc`, `_extras`, `_tls`, `_audit_span`, `_http_span`, `_http_duration`,
  `_metric_series`, `_xlayer` and `run_gpu_host_probe`); six do not
  (`run_otlp_roundtrip`, `_metrics`, `_logs`, `_traces`, `_trace_asm` and
  `_k8s`). The oracle patterns find none of them, so none has a row.
  `run_otlp_kernel_e2e.sh` also decodes with protoc and stays an oracle, for
  its three-path comparison (2026-10-19).

## Validation

On Debian, on `feat/oracle-gate`, nothing ran with `ALLOW_ORACLE=1`.

- `tests/oracle/check.sh` passes on the tree.
- `tests/oracle/run.sh` passes 17/17, including each planted defect.
- The bundled runners ran without the switch, before the 2026-10-19
  classification was applied, under a `ruby` on `PATH` that logged every
  launch:
  - core-boundary, core-report, native-core, gc-arena;
  - every app suite, core, tensor, shader, ebpf;
  - doom, which stopped at a stale manifest that main has since fixed, and
    its negative controls;
  - the gated doom-core lanes. `loop-reports` was cut off at 5400 s, before
    its gated step.

  The log held no oracle launch, and each gated section printed its
  `NOT RUN` line.

## Consequences

**Limits.**

- **File-level, not line-level.** The check matches a file's gate calls with
  its rows. It does not show that every comparison line in a file sits inside
  a gate.
- **Fixtures are not scanned.** A comparison written inside a fixture is
  caught only through the file that runs it.
- **Word-based.** A file is found by words such as `CRuby`, `REF_RUBY`,
  `replay`, `oracle`, `BASELINE_KERNEL` and `doomgeneric`, or by `load ARGV`
  and `require_relative ARGV`. A comparison that uses none of them is not
  found.
- **Two oracles are ungated.**
  - The existing `SPINEL_ORACLE=1` switch is read at run time by
    `examples/tensor`, `examples/image` and `tests/grad/e076/demoA`, and no
    runner sets it.
  - `tests/native-core/macos-probe.py` is Python and is not edited
    (AGENTS.md).

**Follow-up.** In `tests/app/verify.sh` sections 2 and 3, checks that do not
need the replay still wait behind the gate. Running them without it means
splitting expected values such as the replayed count, which is a test change
for the owner to approve.
