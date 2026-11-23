# CORE applications on Zephyr: implementation plan

> **For agentic workers:** Use `superpowers:executing-plans` task by task. The
> implementation is made in one pass on one branch.
>
> - Each task ends with free admission checks, and its admission commands fit
>   in ten minutes in total.
> - Everything longer is listed under "Final verification". It runs once, at the
>   end, on both hosts, as the owner defines it.
> - Do not create additional agents, and do not rebuild shared dependencies
>   concurrently.

**Goal:** A one-file Ruby application compiles as CORE and runs under Zephyr on
QEMU `mps2/an521`. It has timer-driven interrupt entries, thread entries,
cross-context state, UART channels and board devices generated from the
devicetree, and it is verified against CRuby by recording and replay. The same
source builds for FRDM-MCXN947.

**Architecture:**

- **The CORE kernel stays a per-entry compiler.** It gains:
  - an application form of the contract;
  - extern calls through a constant receiver, with guards it checks before the
    call;
  - string literals as constant bytes;
  - atomic lowering of cross-context buffers;
  - a per-entry effect report: writes, extern call counts, and extern stacks
    composed from configuration-bound evidence.
- **A new Ruby application tool** reads the application's declarations. It
  generates the board and channel packages, writes the internal contracts, and
  performs the checks that span entries: one writing context per state, device
  ownership, channel ends, and the stack inequalities. It then generates and
  builds the Zephyr glue, and verifies traces against CRuby.

**Tech stack:**

- LLVM/MLIR 23.1.1 and the existing kernel;
- CRuby with Prism;
- Zephyr and the Zephyr SDK, pinned in Task 1;
- `qemu-system-arm`;
- C for the adapters and glue, compiled by the kernel's clang.

**Spec:** [0014](0014-core-applications-on-zephyr.md), all sections, including
"Authorization and status". Read [0007](0007-doom-core-preparation.md),
[0010](0010-core-resource-contract.md) and the
[buffer boundary](../core/buffer-boundary.md) for the contracts it amends. The
"Coverage" section at the end maps every 0014 validation item to a task and a
test.

## Global constraints and execution

- **Base.** The tip of `docs/0014-plan`, which is Extended `7a7f453` plus this
  plan and 0014's planning clarification. Work on one branch,
  `feat/core-app-zephyr`, in its own worktree. Do not merge `main`,
  force-push or delete branches during this assignment.
- **Pin.** `vendor/spinel` stays at `6d69d010e283ee69118dd47e072a0ecbfbdc87ae`.
  Do not move it. A compiler defect is reported, not patched.
- **Language.** Source comments, maintained documentation and commit messages
  are in English. Commits carry no author signatures, `Co-Authored-By`
  trailers or session URLs.
- **Python** runs only inside the pinned Zephyr installation, for Zephyr's own
  build. No `.py` file enters the repository. Nothing in this repository invokes
  Python except through `west` or Zephyr's CMake.
- **LLVM.** Use the official LLVM 23.1.1 via `LLVM_PREFIX` on both hosts, and
  never Apple Clang. The environment of [building](../building.md) applies to
  every shell.
- **DOOM does not move.** DOOM contracts are `core-contract 1`. Their objects
  and reports stay byte-identical.
- **The mid-course budget.** Each task lists its admission commands, with an
  estimated total. The total must fit in ten minutes.
  - A check that does not fit is not run mid-course. It is added to "Final
    verification" with its estimate, labelled as an estimate.
  - Do not slice a long check into short pieces.
  - A task report lists every control its task defined, and marks each one as
    run, or as carried with the carry-over row that names it. A carried control
    is not a pass.
- **Every check lands with its negative input.** The input that makes a check
  fail lands with it and is kept (0010, "what makes a check a check"). A skip is
  never a pass.
- **A screen control calls the API the way application and glue code spell
  it** -- the public macro or inline -- never the internal symbol the table
  happens to list (the macOS coordinator, 2026-09-23, after Task 10's glue-irq
  control found that `irq_disable()` expands to `arm_irq_disable` on
  Cortex-M, which the table did not list, while Task 7's controls called the
  `arch_` names directly and so could not see it). Any other control that
  names an internal symbol gets the same treatment when next touched.
- **Task reports.** Report each task with its SHA, the exact commands, the
  counts, the skips and the wall-clock time. Continue to the next task without
  waiting.
- **Owner decisions.** Stop only for a decision that changes the accepted
  contract, and give it to the owner with a concrete proposal. The decisions so
  far are listed under "Owner decisions".
- **Interfaces are normative.** The formats in "Interfaces" below are part of
  this plan. A task that needs to change one updates that section in the same
  commit and says so. A change that would alter 0014's observable behaviour is
  an owner decision, not a plan edit.

**Baseline for the DOOM admission check.** At the start of Task 2, build the
kernel once from `7a7f453` in a separate worktree, and record the binary's
sha256 and the build command in the task report. Every later admission check
uses that binary as its baseline, not whatever `main` is at the time.

**The DOOM admission check** (an estimate of about 5 minutes: it builds the four
objects measured on 2026-09-21, and `renderall` alone took 107–152 s per build
then). It builds `col`, `renderall`, `lindex` and `fplane` with the baseline
kernel and with the branch's kernel, and compares objects and v1 reports. Any
difference stops the task.

- *Measured in Task 2 (Debian, 2026-09-22): 1011 s for the full form, of which
  `renderall` 439 s.* That is past the ten-minute rule, so the macOS coordinator
  settled the mid-course form for Tasks 3–5: `--mid-course` builds `col`,
  `lindex` and `fplane`, compares objects and headers, builds and compares the
  report for `col` only, and runs the `col` control; measured at 413 s (col 160, lindex 80, fplane 77, the controls the rest).
  `renderall`, and every other report identity, are checked by the 42-entry
  comparison of the final verification.

```sh
sh tests/app/doom-admission.sh --baseline-kernel "$BASELINE_KERNEL" --kernel "$BRANCH_KERNEL" --mid-course
```

The full 42-entry comparison is part of the final verification.

## Owner decisions

- **D1. Compiler runtime helpers on 32-bit ARM.** Approved for now by the owner
  on 2026-09-22, with "Approved for now" (the owner's words, translated).
  - CORE computes in 64 bits (D3 deferred the 32-bit mode). On Cortex-M33, 64-bit division
    lowers to `__aeabi_ldivmod` or `__aeabi_uldivmod`. The predecessor measured
    this at spinel-llvm `463d49dd` (`docs/tools/zephyr-sdk.md`,
    `docs/experiments/E040_freestanding_m1.md`), and found that the Zephyr SDK's
    libgcc resolves those helpers for LLVM-built objects, as the ARM EABI
    specifies.
  - The fixed list of helpers that the probes of Tasks 2 and 5 establish is
    admitted as board-package externs. Their effects (pure, no allocation, no
    blocking, `isr_ok`) are attested. Their stack is attested, because libgcc is
    GCC-built and the 0010 step 2 method does not apply to it.
  - Admission is by name, never by prefix.
- **D2. An out-of-range device index is a `BOUNDS` failure.** Approved for now by
  the owner on 2026-09-22.
  - It is established by a kernel `guard` before the adapter call. The adapter
    never receives an out-of-range index.
- **D3. A 32-bit integer mode for CORE applications.** Decided by the owner on
  2026-09-22, with "Then shall we take option 2 for D3?" (the owner's words,
  translated): DEFERRED. This milestone is 64-bit only,
  with D1's `__aeabi_ldivmod` admitted by name; the 32-bit mode is decided at
  the next stage, on measurement. Task 11 records, per entry of the acceptance
  sample, the instructions per invocation and how many of them run inside
  `__aeabi_ldivmod` (QEMU `icount` makes the counts deterministic), as report
  fields, so that decision will have data. The proposal, kept for that stage:
  - `integer_width 32` at the top level of an application makes every entry
    compute in the signed 32-bit domain, with the same checked semantics.
    Leaving that domain is `ARITHMETIC`. The default is 64.
  - Literals outside the domain are refused at build, and so are `i64` states
    and `i64` extern scalars.
  - The CRuby oracle checks the 32-bit domain.
  - DOOM is unaffected.
  - Implementing it means the kernel's integer type becomes a parameter, 32 or
    64.
- **D4. The channel method names. DECIDED by the owner on 2026-09-23:
  `put`/`get` is final, the names as built.** 0014 §5 names them `send` and
  `recv`, and `send` is Ruby's
  dynamic dispatch. The pinned analyser expands `X.send(...)` into candidate
  calls named by every string literal of the calling method (and by the
  declaration's keyword symbols when the module body carries one), which the
  reader then refuses as a dangling reference; and at the CRuby host
  `Telemetry.send(buf, n)` resolves to `Object#send` unless the generated
  module shadows it. Proposal (B): rename to `put` and `get` (`Telemetry.put`,
  `Telemetry.get`; symbols `spc_channel_<name>_put` / `_get`; trace kinds
  `ENQ`/`DEQ` unchanged). Alternative (A): keep the surface names and have
  Task 6's packaging rewrite `.send(` to a kernel-only spelling. Task 3's
  fixtures use `put`/`get`. The reason, recorded with the decision: `send` is
  `Object#send`, so the name is taken three times over -- the pinned analyser
  expands `X.send(...)` into candidate calls named by every string literal of
  the calling method and the reader then refuses the dangling reference, and
  at the CRuby host `Telemetry.send(buf, n)` reaches `Object#send` unless the
  generated module shadows it. The word "provisional" is removed wherever it
  described these names.

- **D5. Board constants as `Mod::NAME`. DECIDED by the owner on 2026-09-23:
  option 1, single-level module constants.** `Mod` is a module in the packed
  root and `NAME` an integer literal written directly in its body; the
  generated board package carries the alias, label and node-name constants
  under those names inside the module, so an application writes `Led::LED0`
  and `Led::COUNT` and nothing needs a prefix. Four refusals, each with a
  fixture: a nested `A::B::C`, a non-integer constant in a module body, an
  unknown module or name, and a redefinition. Task 3's module rule still
  refuses a module that holds anything else, with its fixture still refusing.
  (Done, 2026-09-23. `Eligibility` resolves the path and names each failure
  where it sits, `Importer` admits `ConstantPathNode` on the application lane
  only, `MlirGen` resolves it inside the named module -- a bare name never
  reaches a module's constant -- and `LoopBounds` folds it, so `Led::COUNT`
  bounds a loop and renders as `(const Led::COUNT)` in the bound digest. The
  packer emits each module with its constants in its body; the reader records
  them as `Mod::NAME` and refuses a top-level one even in a package.
  `tests/app/contract.sh` carries the four refusals and the accepted form
  (`Adc::COUNT` as a loop bound, `Adc::CH0` as an extern argument);
  `tests/app/effects.sh` checks that `const_args` carries the value; the
  host's device-owner fixture now names its two instances by board constants,
  so the ownership rule reads those values. The packer emits a module's
  constants whether or not the application declares its own member on that
  module -- the preflight found that dropping them left `Led::LED0`
  unresolvable in exactly the applications that extend `Led`, with no fixture
  covering it; `apps/own-extern-board` covers it now, and it is refused
  without the fix.
  An honest boundary the preflight also named: the kernel's module rule
  admits an integer constant in ANY top-level module body of an application,
  including one the application wrote itself, while the tool's reader admits
  them only in a generated package. The tool is the gate, so nothing reaches
  the kernel that way; the kernel's looser rule is unexercised and
  unchecked.)

## Target facts that bind the implementation

These were found by rereading the predecessor's records before
implementation. The records are at spinel-llvm `463d49dd`: `docs/tools/zephyr.md`,
`zephyr-sdk.md`, `qemu.md`, and `docs/experiments/E040_freestanding_m1.md`.
Some were also checked in the Mac's existing Zephyr workspace.

- **Unwind references.** An ARM object without `nounwind` references
  `__aeabi_unwind_cpp_pr0` (E040 case `e06`). The kernel must emit CORE
  functions `nounwind`, with no unwind tables. Task 2 checks the undefined set
  for it.
  - *Measured in Task 2 (the Mac, 2026-09-22).* The kernel had never emitted
    the attribute: the optimiser inferred it at `-Os`, and at `-O0` every
    probe object referenced the personality routine. The kernel now marks
    every function it emits `nounwind` itself (`HostEmitRequest::noUnwind`),
    and `cross.sh` builds an entry at `-O0` and requires no personality
    reference and the attribute on every definition. "No unwind tables" means
    *no personality reference*: the ARM backend still writes one `CantUnwind`
    entry per function into `.ARM.exidx` (8 bytes, no symbol), and those
    remain. Task 10 confirms that Zephyr's linker script places `.ARM.exidx`
    without an orphan-section warning.
- **FP build attributes.** Clang with `-mcpu=cortex-m33` stamps an FP
  architecture attribute even for soft-float code, which can disagree with
  Zephyr's GCC objects. Task 2 matches the build attributes (`llvm-readelf -A`)
  of our objects with a Zephyr object of the same build, and pins the `-mcpu`
  and `-mfpu` spelling that makes them agree.
- **The `mps2/an521/cpu0` flags** are
  `-mcpu=cortex-m33+nodsp -mthumb -mabi=aapcs -mfp16-format=ieee -mtp=soft -mcmse`,
  soft-float, with picolibc and `CONFIG_LIBGCC_RTLIB=y`. `-mcmse` means a
  secure image. This is recorded as the security assumption.
- **QEMU does not exit.** `west build -t run` does not terminate, because Zephyr
  idles. Task 11's runner stops QEMU after it has drained the end marker, or at
  `H` plus `D` plus a margin. Either way it records which.
- **SDK selection.** `~/.cmake/packages/Zephyr-sdk` can override
  `ZEPHYR_SDK_INSTALL_DIR`. The Mac has two registrations, SDK 1.0.1 and 0.17.0.
  The tool passes the SDK explicitly, and Task 1 confirms from the CMake log
  which SDK was used.
  - *Added in Task 1 from the Mac's measurement (2026-09-22), confirmed on
    Debian.* `ZEPHYR_SDK_INSTALL_DIR` is not authoritative, and turning the
    registry off does not make it so: the pinned
    `cmake/modules/FindZephyr-sdk.cmake:81-83` passes it as `HINTS`, so a
    path that names no SDK falls through to CMake's default search (the
    registry on Debian; a `$HOME` prefix on `PATH` on the Mac), and the
    configure succeeds silently with whatever it finds. The only defence is
    the log: the tool and `platform-facts.sh` compare
    `-- Found toolchain: zephyr <version> (<path>)` with the intended SDK's
    `sdk_version` and canonical path, and refuse on mismatch. The measured
    rows are in `docs/toolchains/zephyr-v4.4.2/INSTALLATION-RECORD.md`.
  - *Also from the Mac's measurement.* `west build -t run` runs the SDK's
    QEMU (`QEMU:FILEPATH` in `CMakeCache.txt`), not the system one; records
    name that binary.
- **No float ABI on the compile line.** *Added in Task 1 from the Mac's
  measurement.* The `mps2/an521/cpu0` compile line in `compile_commands.json`
  has no `-mfloat-abi` and no `-mfpu`: soft-float is GCC's default for
  `arm-zephyr-eabi`. Flags taken from `compile_commands.json` therefore hand
  clang no float ABI. Task 2 passes `-mfloat-abi=soft` explicitly, with the
  `-mfpu` spelling its FP-attribute check settles.
- **The 64-bit cycle counter needs a configuration option.** *Added in Task 1
  from Debian's measurement.* SysTick on `mps2/an521` runs at 25 MHz, below the
  60 MHz at which Zephyr enables `CORTEX_M_SYSTICK_64BIT_CYCLE_COUNTER` by
  default; without it `k_cycle_get_64()` returns 0. With it set, the counter
  advances inside a busy-waiting `k_timer` expiry (50217 cycles over 2000 µs),
  so the dedicated hardware timer of 0014 §4 is not needed. The generated
  `prj.conf` sets it.
- **Existing installations.** The Mac has a Zephyr workspace at
  `~/sdk/zephyrproject` (`v4.4.0-3236-g7fd932b9357`, a development snapshot),
  with `west` 1.5.0 in another project's conda environment. It also has SDK
  1.0.1, and so does Debian.
  - Task 1 pins a tagged 4.4 release with SDK 1.0.1, in a dedicated
    environment.
  - It does not reuse the snapshot or that conda environment.
- **FRDM-MCXN947.** The board target is `frdm_mcxn947/mcxn947/cpu0`, whose
  defconfig selects `CONFIG_TRUSTED_EXECUTION_SECURE=y` and `CONFIG_ARM_MPU=y`.
  Its devicetree has `gpio-leds` and, in the snapshot, no `pwm-leds`, so the
  `Pwm` sample's condition is expected not to hold. Task 1 confirms both on the
  pinned release. 512 KB of SRAM bounds the application's memory.
- **The official LLVM's `ld.lld` does not run on the Debian host.** *Added in
  Task 8 (2026-09-23).* `/opt/llvm-23.1.1/bin/ld.lld` fails to load:
  `ld.lld: error while loading shared libraries: libicui18n.so.70: cannot open
  shared object file: No such file or directory` (Debian 13.6; `ldd` names
  `libicui18n.so.70`, `libicuuc.so.70` and `libicudata.so.70` as not found).
  Every `thumbv8m` link therefore uses the Zephyr SDK's GNU linker,
  `arm-zephyr-eabi-ld` under `ZEPHYR_SDK_INSTALL_DIR`, which is the linker
  Zephyr's own build uses: `tests/app/channel.sh` links its two-channel
  fixture with it, and Tasks 10 and 11 link through `west build`, so nothing
  on this branch needs `ld.lld`. The installation record's Debian section has
  the command and the line.
- **macOS `/bin/sh` is bash 3.2.57, and a suite written on Debian meets it
  there.** *Added in Task 10 from the Mac's measurement (2026-09-23).* bash 3.2
  mangles a MULTI-LINE command substitution whose body holds an index with a
  comma beside a nested double quote. It runs the command, then evaluates the
  text a second time with the quoting gone, so the interpreter reports a syntax
  error and the check reads the program's own source as its answer. The smallest
  reproduction, which fails under `/bin/sh` and passes under `dash`:

  ```sh
  ok() { echo "got=[$2]"; }
  ok x "$(ruby -e 'b = "abcd"; i = 0
                   puts "f:#{b[i, 4] == "abcd" ? "yes" : "no"}"')"
  ```

  Put the program on one line, drop the comma index, or run it outside a
  function argument, and both shells agree. **The form to write is the value
  first**, which both parse: `got=$(ruby -e '...' || true)`, then
  `ok "..." "$got" "..."`. That is what `tests/app/build.sh` does at `010a7a0`.
  - SCANNED, 2026-09-23: this is the ONLY occurrence in `tests/`. The only other
    index-with-comma inside a multi-line substitution is in a Python heredoc in
    `tests/doom/negative-controls.sh`, which is not a substitution. The wider
    shape -- nested quotes inside a `#{}` interpolation in a multi-line
    substitution passed to a function -- is in `tests/app/board.sh`,
    `tests/app/cross.sh` and two `tests/doom-core` suites, and all of them pass
    under bash 3.2. The comma index is the trigger, not the shape.
  - Its relatives, also measured on the Mac: an assignment in front of a shell
    FUNCTION call persists under bash 3.2 and is dropped by dash, so
    `XFLAGS=-O0 build …` left every later build at `-O0` (`tests/app/cross.sh`,
    fixed at `8082dd0`); and BSD `sed` has no `\t`.
  - Running a suite under `dash` as well as `/bin/sh` on the Mac is what
    separates this family from a defect in the code under test. `dash` is
    installed there.

```
tools/app/
  bin/spinel-core-app             CLI: board | run-host | build | verify
  lib/spinel/core.rb              no-op declarations for CRuby: state, every_us, every_ms,
                                  channel, core_extern
  lib/spinel/net.rb               put_u8, put_u16, put_i32, put_str, put_dec (admitted CORE Ruby)
  lib/core_app/app_model.rb       App, State, Trigger, Channel, Extern, Entry value objects
  lib/core_app/declarations.rb    reads declarations with Prism into an App
  lib/core_app/channels.rb        generates the channel package (Ruby modules and C)
  lib/core_app/dts.rb             reads a final zephyr.dts into a node tree
  lib/core_app/board.rb           generates the board package
  lib/core_app/evidence.rb        provider evidence files: write, read, bind to configuration
  lib/core_app/contracts.rb       writes core-contract 2 for each entry
  lib/core_app/app_checks.rb      cross-entry rules
  lib/core_app/reserves.rb        attested reserves and driver rows: applicability predicates
  lib/core_app/stack.rb           the two inequalities of 0014 §9
  lib/core_app/inventory.rb       interrupt inventory and vector-slot classes
  lib/core_app/glue.rb            renders the Zephyr application
  lib/core_app/pipeline.rb        the eleven build steps, staging and publication
  lib/core_app/host_runner.rb     CRuby on a virtual clock, with checked domains
  lib/core_app/trace_schema.tsv   the single trace schema; the C recorder header and the decoder
                                  are both generated from it
  lib/core_app/trace.rb           decoder
  lib/core_app/verify.rb          the four checks and the replay
  templates/                      *.c.erb, *.h.erb, CMakeLists.txt.erb, prj.conf.erb, app.overlay.erb
  adapters/{led,button,pwm,adc,clock}/adapter.c, adapter.h, sim.rb, class.tsv
  zephyr/<release>/effects.tsv, irq-rows.tsv, reserves.tsv, vector-classes.tsv, screen.tsv
  zephyr/<release>/boards/<board>.tsv
  zephyr/<release>/reserve-harness/   non-deliverable Zephyr apps that produce reserve evidence
tools/mlir/native/                      kernel changes (Tasks 2-5)
tools/mlir/native/schema/core-report-v2.schema.json
tools/core/core-artifact-gate           gains --extern and object-format-aware names
tests/app/                              run.sh, suites and fixtures of Tasks 2-13
docs/toolchains/zephyr-<release>/INSTALLATION-RECORD.md
docs/core/applications.md               user guide (Task 13)
```

## Interfaces

These formats are fixed by this plan. Names that 0014 calls provisional are
fixed here for the implementation; `put`/`get` is no longer among them (D4,
decided).

### Application declarations (Ruby, read with Prism)

- **Placement.** Declarations appear only at the top level of the file, or
  directly in a `module` body. A non-literal argument is refused, with its
  location.
- `state :name, :u8|:i32|:u32|:i64, count`, where `count` is an integer literal
  of at least 1.
- `every_us n, :entry, context: :thread|:interrupt` and `every_ms n, :entry, …`,
  where `n` is an integer literal of at least 1.
  - An entry named by two triggers is refused.
  - So is a trigger naming no top-level `def`.
- `channel :name, :out|:in, size: s, depth: d, uart: true`.
  - It generates a module named after the channel (`:telemetry` gives
    `Telemetry`), with the two externs of "Channel package".
  - `udp:` and `mqtt:` are refused as not implemented in this milestone.
- `core_extern`, inside `module M`:

  ```ruby
  core_extern :fn, params: {name: :u32, data: [:buf, :u8]}, returns: :i32,
              reads: [:data], writes: [], isr_ok: true,
              bound: "iterations 1", provider: "drivers/x.c"
  ```

  - `params` is an ordered hash from names to `:i32`, `:u32` or `:i64`, or to
    `[:buf, :u8|:i32|:u32|:i64]`.
  - A buffer parameter is read-only (`in`) unless it is listed in `writes:`.
    `writes:` naming a parameter that is not also allowed to be written is
    refused as `writes-on-in`.
  - `bound` and `provider` are required.
  - An application-authored `core_extern` has no `requires:` keyword.
    Preconditions are internal: only the generated channel and board packages
    carry them, to realise failures that 0014 fixes (channels), or that the owner
    decides (D2). A public precondition surface would be a new declaration
    feature for the owner.
- **Entries.** An entry is a top-level `def` named by a trigger. Each parameter
  name equals a declared `state`. There are no other entry parameters.

### Extern preconditions (internal to generated packages)

```
guard  <operand> (< | <= | > | >= | == | !=) <operand> else (argument | bounds)
static <operand> (< | <= | > | >= | == | !=) <operand> else <diagnostic-code>
operand := <param name> | <integer literal> | len(<buffer param>)
```

- **`guard` is a run-time check.** The kernel emits each `guard` before the
  call, in declared order.
  - A false guard makes the entry fail with the named 0007 status. The extern
    is not called, and effects before the call remain, as 0007 specifies.
  - This is a compiler-established failure, like a buffer-index `BOUNDS`. The
    application's `core_fail` stays `:capacity` only.
  - **Constant folding must not change the behaviour.** A guard that is false
    for constant operands at a call site becomes an unconditional failure *at
    that call site*. It is not a build refusal. A call on an untaken path
    therefore never fails the entry.
- **`static` is a build-time requirement.** It must be decidable from constant
  operands at every call site, and a false one refuses the build with its
  diagnostic code. It is used only where 0014 makes the condition a build
  error: the `recv` capacity check, `channel-buffer`.

### Channel package (generated per application)

For `channel :telemetry, :out, size: 16, depth: 8, uart: true`:

```ruby
module Telemetry
  core_extern :send, params: {data: [:buf, :u8], n: :u32}, reads: [:data], returns: :i32,
              isr_ok: true, bound: "iterations 16", provider: "<generated channel C>",
              guards: ["n >= 1 else argument", "n <= 16 else bounds", "n <= len(data) else bounds"]
end
```

For `:in`:

```ruby
core_extern :recv, params: {data: [:buf, :u8]}, writes: [:data], returns: :i32,
            isr_ok: true, bound: "iterations <size>",
            statics: ["len(data) >= <size> else channel-buffer"]
```

- `send` returns 1 when the message is queued and 0 when the queue is full.
  `recv` returns the length, or 0 when the queue is empty. Neither C function
  ever returns a failure. Every failure of 0014 §5 is a `guard`.
- The `recv` capacity is a `static`. Entry buffers have constant counts, so a
  short buffer is refused at build as `channel-buffer`, as 0014 specifies.
- `guards:` and `statics:` are keywords of generated `core_extern`s only. The
  declaration reader refuses them in application source.

### `core-contract 2` (written by the tool, one per application entry)

```
core-contract 2
root <packaged root>
entry <name>
context thread | context interrupt
result none
param <name> buffer <u8|i32|u32|i64> inout count const <N> [cross]
extern <Module>.<fn> symbol <c_symbol> [arg <name> <i32|u32|i64>]... [arg <name> buffer <elem> <in|inout>]... [returns <i32|u32|i64>] [isr_ok] [guard <condition>]... [static <condition>]... bound iterations <expr> evidence <path>
```

- Version 1 is unchanged. Version 2 without `context` is refused, and a v1
  contract with an `extern` line is refused.
- `arg` lines keep the declaration's order and names. The mode of a buffer
  `arg` comes from `writes:`. Effects refer to `arg` names.
- `cross` marks a state reached from more than one context, and selects atomic
  lowering.

### C ABI

- **Entry.** `int32_t <entry>(<elem> *<p1>, …)`.
  - It returns the 0007 status.
  - There are no count parameters and no result pointer.
  - Pointers are aligned to their element size.
- **Extern.** `<ret|void> <c_symbol>(…)`, with the parameters in declared
  order.
  - A scalar is `int32_t`, `uint32_t` or `int64_t`.
  - **A buffer argument is two C parameters: `<elem> *name`, then
    `uint32_t name_len`**, its count in elements. `in` buffers are `const`.
  - A state buffer passes its constant count. A literal passes its byte length.
- **Headers.** The generated extern prototype header is included by the
  provider's C file. A provider whose definition disagrees with that header
  therefore fails to compile, which is the signature diagnostic.

### Provider evidence (`<staging>/evidence/<symbol>.json`)

```json
{"format": "spinel-provider-evidence", "version": 1,
 "symbol": "spc_board_adc_latest", "object": {"file": "...", "sha256": "..."},
 "target": "thumbv8m.main-none-eabi", "board": "mps2/an521/cpu0",
 "zephyr_release": "...", "dts_sha256": "...", "config_sha256": "...", "flags_sha256": "...",
 "stack": {"bytes": 24, "method": "0010 step 2 frame sizes over the object's final IR"},
 "effects": {"isr_ok": true, "blocking": false, "row": "effects.tsv:<line>"},
 "provenance": "attested"}
```

- **Binding.** The kernel receives `--config-binding <dts>:<config>:<flags>`.
  It accepts an evidence file only if all three digests, the target and the
  symbol match. A mismatch makes the extern's stack and effects `unknown`, with
  a reason.
- **Evidence kinds.** The report records the extern's evidence as
  `attestation`. The frame measurement is an input to that attestation, not a
  `measurement` of the entry.

### `core-report-v2`

The schema is `tools/mlir/native/schema/core-report-v2.schema.json`. It is
`core-report-v1` plus a required top-level `application` object:

```json
"application": {
  "context": "thread|interrupt",
  "buffers": [{"name": "target", "cross": true, "written": false, "elements": 1}],
  "externs": [{"name": "Adc.latest", "symbol": "spc_board_adc_latest", "calls": "1",
               "sites": 1, "const_args": [[0]],
               "isr_ok": true, "bound": "iterations 1",
               "guards": ["index < 1 else bounds"],
               "stack": {"bytes": 24, "evidence": "attestation",
                         "artifact": {"file": "...", "sha256": "..."}}}],
  "work_bound": {"expression": "...", "extern_terms": ["..."]}
}
```

- `calls` is an expression: the sum, over call sites, of the product of the
  enclosing derived bounds, composed through helpers. Both arms of a
  conditional are counted.
- `written` is the transitive write effect.
- `const_args` holds one array per call site of the extern in the source,
  with, per declared argument, the integer literal or resolved constant
  passed there, or `null` for a buffer or a computed scalar. The application
  tool reads a device's instance index from it. `sites` counts the loop
  expansion's occurrences, which differs when a helper is reached along
  several paths.
- `properties.extern_effects` passes only when every extern is declared,
  `isr_ok` holds in interrupt context, no cross buffer reaches an extern, every
  `calls` is derived, and every extern's evidence is bound to this
  configuration.
- DOOM entries keep writing v1. `tests/core-report/run.sh` gains v2 schema
  validation for v2 fixtures.

### Board package (per build, `<staging>/board/`)

- **`spinel/board.rb`.** One module per device class and effect group, with
  constants for the count and for each alias or label, and one `core_extern` per
  function. The constants are written in their own module and unprefixed
  (`Led::COUNT`, `Led::LED0`): since D5 that is what the checked boundary
  resolves, and it is what CRuby resolves natively. A generated name that
  would collide inside a module is refused by name.
- **`spinel/board_host.rb`.** The same modules with CRuby bodies, from
  `adapters/<class>/sim.rb`. `Clock.cycles` on the host returns the virtual
  clock in microseconds, not a cycle count; no fixture calls `Clock` yet.
- **`board_port.c`.** For each class, a table from index to devicetree instance,
  and `spc_board_<class>_<fn>` functions.
- **`board.tsv`.** One row per instance:
  `module  index  name  node_path  compatible  bus  isr_ok  blocking  evidence`.
  Ownership is by `node_path`.

### Tables under `tools/app/zephyr/<release>/`

- Every row that makes a claim carries `evidence`: a URL at the pinned commit,
  or a file under `reserve-harness/`.
- Every row is guarded by `applies_when`: a comma-separated list of
  `CONFIG_X=value` predicates, and optionally `board=<name>`. A row applies only
  if every predicate holds in the build's `.config` and board.
- A needed row with no applicable match is never defaulted. It makes the
  verdict `unknown`, or refuses the build, as 0014 specifies.

| file | columns |
|---|---|
| `effects.tsv` | `compatible bus isr_ok blocking applies_when evidence` |
| `irq-rows.tsv` | `compatible irq_source priority_source post_init_changes envelope applies_when evidence` |
| `reserves.tsv` | `item bytes method applies_when evidence` (items `thread_switch`, `thread_kernel_calls`, `isr_entry_exit`, `pendsv`, `timer_dispatch`, `uart_calls`, `guard_area`, one per driver interrupt handler) |
| `vector-classes.tsv` | `class symbol` (class `reset`, `terminal` or `default`) |
| `screen.tsv` | `set symbol reason` (sets `alloc`, `block`, `irqconfig`) |
| `boards/<board>.tsv` | `key value evidence` (`max_thread_stack`, `ram_bytes`, `single_core`, `security`) |

### Trace

- **One schema.** The trace is defined by one schema file,
  `lib/core_app/trace_schema.tsv`, with one row per field:
  `kind_id kind field type`.
  - The C recorder header is generated from it at build time.
  - The Ruby decoder reads it.
  - Checked-in fixture byte streams, one per kind, are decoded by the tests.
- **Field types in the schema** are exactly these: `u8`, `u16`, `u32`, `u64`,
  `i32`, `i64`, `bytes` and `args`.
  - All integers are little-endian.
  - `bytes` is a `u32` length followed by that many bytes.
  - `args` is a `u8` count, then that many tagged values. Tag `0` is a scalar,
    followed by an `i64`. Tag `1` is a buffer, followed by `bytes`.
  - No other encoding exists. Enumerated fields are `u8` codes, listed in the
    schema file's code table (below).
- **Record layout.** Each record is a common header, then its fields in schema
  order:

  ```
  u32 magic "SPTR"; u16 schema_version; u16 kind; u32 body_len; u32 seq; u8 context; u8 entry; u16 pad
  ```

  - `body_len` is the byte length of the fields that follow. The decoder
    refuses a record whose fields do not consume exactly `body_len` bytes.
  - The schema file's code table fixes these codes:
    - `ENQ` result: 0 queued, 1 full;
    - `DEQ` result: 0 dequeued, 1 empty;
    - `DROP` reason: 1 oversize, 2 channel_full.
  - `HEADER` counts are one `u8` each.
  - The byte fixtures pin every type, tag and code.

  `context` is 0 for the scheduler thread, 1 for the transport thread, 2 for
  the stimulus thread, and 3 and above for interrupt sources in inventory order.
  `entry` is 255 for non-entry actors.

**Record kinds:**

| kind | fields |
|---|---|
| `HEADER` (0) | epoch u64, clock_hz u32, horizon u64, drain u64, counts of contexts, entries, states and channels |
| `SELECT` | clock u64, release u32, skipped_from u32, skipped_to u32 |
| `START` / `END` | release u32 |
| `LOAD` / `STORE` | state u8, index u32, value i64 |
| `XCALL` | extern u16, argc u8, then per argument a tag (scalar i64, or buffer bytes u32 + bytes) |
| `XRET` | extern u16, value i64 |
| `ENQ` / `DEQ` | channel u8, msg_id u32, result u8, length u32, payload |
| `RX` | channel u8, stimulus_id u32, length u32 |
| `TX` | channel u8, msg_id u32 |
| `DROP` | channel u8, stimulus_id u32, reason u8 |
| `STATUS` | status i32 |
| `FAIL` | status i32, release u32 |
| `CANCEL` | entry u8, from u32, to u32, fail_seq u32 |
| `CUT` | entry u8, from u32, to u32 |
| `PRIVATE` | state u8, bytes u32, bytes |
| `OVERFLOW` | context u8 |
| `ENDMARK` | quiescent u8, drained u8 |

- **Limits.** More than 250 contexts, entries, states or channels, or a run
  whose sequence would exceed 2^32 − 1, is refused at build time.
- **Transport contexts.** `RX`, `TX` and `DROP` are written in the transport
  context. `FAIL` and `CANCEL` are written in the failing context. A `CANCEL`
  names the `FAIL` it follows.
- **As built (Task 11).** The target's `stimulus_id` in `RX` and `DROP` is
  the inbound frame's ordinal on its channel (the transport numbers what it
  receives; it cannot know the script's item numbers), and the check maps
  the script's k-th inbound item of a channel to ordinal k. The nesting
  source logs each handler entry and exit as `START` and `END` with entry
  255 in its own context, so nesting is read from the trace. The end
  sequence prints, after the end marker, `SPC_CYCLES` (per entry: the
  invocations, the cycles inside them, the `__aeabi_ldivmod` calls and their
  cycles), `SPC_STACK` (each painted stack's high-water mark and size) and
  `SPC_END dropped= transport_passes=`; `verify` reads them into its report.
  A production build refuses an entry whose object calls the libgcc 64-bit
  division helpers (their stack is not attested: D3); a verification build
  admits them so the run can measure them.
- **The icount shift is part of every recorded figure** (the macOS coordinator,
  2026-09-23), as the flags are part of every digest: under QEMU an
  instruction takes 2^shift ns of virtual time, so a release count, a
  transport pass count, a stack mark or an instruction count recorded at
  one shift is not comparable with one recorded at another (at the board's
  default 7 the recorded build starves its transport thread; `verify` runs
  at 5). `report.json` names the shift in its method line, and a figure
  quoted from a run names it too.

### Stimulus script (TSV)

```
horizon_us <H>
drain_us <D>
adc <t_us> <channel> <millivolts>
gpio <t_us> <pin> <0|1>
inbound <t_us> <channel> <hex payload>
cost <entry> <release|*> <us>
nest_timer <period_us> <busy_us>
expect_failure <entry> <release> <status>
```

- **`cost`** gives the virtual execution time of an invocation, for the host
  runner only. It is simulation input, not a WCET estimate. Idle time is not a
  cost: the host clock jumps to the next event. On the target, busy work comes
  from a bounded loop in the fixture's Ruby.
- **`nest_timer`** enables the verification-only nesting source of Task 11.

## Task 1: Pin Zephyr and confirm the platform facts

**Files:**

- Create `docs/toolchains/zephyr-<release>/INSTALLATION-RECORD.md`.
- Create `tools/app/zephyr/<release>/boards/{mps2_an521,frdm_mcxn947}.tsv`.
- Create `tests/app/platform-facts.sh`.
- Update [provenance](../provenance.md) and [building](../building.md).

**Interfaces:** the installation record names:

- the release and its commit;
- the SDK version;
- the west manifest revision;
- the Python version and the requirements hash, inside the installation;
- the install paths on each host;
- the `qemu-system-arm` version.

The tool reads `ZEPHYR_BASE` and `ZEPHYR_SDK_INSTALL_DIR`, and refuses to run
without them.

- [x] **Choose the release.** It must support `mps2/an521/cpu0` under QEMU and a
  FRDM-MCXN947 board target, and have an SDK for Debian x86_64 and macOS arm64.
  Debian has SDK 1.0.1 at `~/zephyr-sdk-1.0.1`; prefer a release it supports.
  Record the reason for the choice.
- [x] **Install on both hosts**, outside the repository. The Mac installation is
  done in parallel by the Mac host, with the same release, record and commands.
- [x] **`platform-facts.sh`** builds `hello_world` and a timer probe for
  `mps2/an521/cpu0`. It establishes, and prints with each fact the command that
  produced it:
  - `zephyr.dts` exists after configure;
  - `compile_commands.json` exists;
  - QEMU prints the banner;
  - `k_cycle_get_64()` advances inside a `k_timer` expiry that busy-waits;
  - the ADC and GPIO emulators build with an overlay;
  - `mps2/an521` has no ADC or PWM node, and a lower-priority hardware timer
    exists for nesting (for example a CMSDK timer);
  - the FRDM-MCXN947 board target configures, and whether it has `pwm-leds`.
- [x] **Control:** an empty `ZEPHYR_BASE` fails by name.
- [x] **Record the answers** in the board TSVs and the installation record. If
  the cycle counter does not advance, select the dedicated hardware timer of
  0014 §4, and record why.

**Admission:** `platform-facts.sh`, timed separately from the first Zephyr build,
which is installation. Estimated at 5 minutes.

## Task 2: Cross-build for Cortex-M33

**Files:**

- Modify `tools/mlir/native/lib/Core/StackBudget.cpp`: the overhead row.
- Modify `tools/core/core-artifact-gate`: `--extern`, and symbol normalisation
  decided by the object's format, read with `llvm-readobj --file-headers`, not
  by the host's `uname`.
- Modify `tools/mlir/native/tools/spinel-core-kernel/main.cpp` and
  `lib/Core/Boundary.cpp`: `--layout` derived from the target's data layout.
- Audit `lib/Core/Kernel.cpp`: the descriptor pointer arithmetic and 64-bit
  limits (around its lines 293–295 and 366–387) for a 32-bit target.
- Create `tests/app/doom-admission.sh`, `tests/app/cross.sh` and
  `tests/app/fixtures/cross/`.

**Interfaces:**

- The tool passes `--target=thumbv8m.main-none-eabi`, plus `-mcpu`,
  `-mfloat-abi=soft`, `-mthumb` and `-O` from `compile_commands.json`, after
  `--`.
  - *Fixed in Task 2 (2026-09-22), from measurement.* The CORE codegen line is
    `--target=thumbv8m.main-none-eabi -mcpu=cortex-m33+nodsp -mfloat-abi=soft -mthumb -Os`:
    `-mcpu` and `-Os` as `compile_commands.json` records them, `-mfloat-abi=soft`
    added because the line records no float ABI (without it clang assumes an
    FPU and stamps `FP_arch`; CMSIS refuses an adapter outright), `+nodsp`
    kept because it is what keeps `DSP_extension` off the object. With these
    the build attributes both objects carry agree with Zephyr's GCC objects,
    except the optimisation goal and the FP exception model, which the linker
    merges (`tests/app/cross.sh`, item 5).
  - Adapters and glue, compiled from C against Zephyr's headers, take the
    `compile_commands.json` line with six flags dropped (`-fno-printf-return-value`,
    `-fno-reorder-functions`, `-mfp16-format=ieee`, which clang rejects;
    `-fno-defer-pop`, `--param=min-pagesize=0`, `-specs=picolibc.specs`, which
    it ignores) and two added: `-mfloat-abi=soft`, and `-fshort-enums`, GCC's
    default for `arm-none-eabi`, without which `sizeof` a small enum is 4 in our
    objects and 1 in Zephyr's (`ABI_enum_size` Int32 against Packed; measured
    on `enum small { A, B }` and a struct holding it, 4/12 against 1/3). The
    lists are `tests/app/fixtures/cross/rejected-flags.txt` and
    `dropped-flags.txt`.
- The kernel requires `--layout` whenever `--target` differs from the host.
  The layout is derived from `clang -print-target-triple` and the target's
  pointer and `long` sizes.
  - *Fixed in Task 2.* The kernel derives `ptr<N>-i64-<M>long` from the triple
    clang reports for the caller's arguments, refuses a cross target given
    without `--layout` (naming the value to pass), and refuses a `--layout`
    that disagrees with the triple. A host build without `--layout` is
    unchanged. The same width selects a second descriptor guard on 32-bit
    targets: `base + size` must not pass `2^32 - 1`, since in 64-bit
    arithmetic it cannot wrap there (the Kernel.cpp audit; a host build emits
    no such guard, so DOOM's objects are unchanged).
- The per-call stack overhead of `thumbv8m` is 0, as on arm64: `bl` writes
  no stack and the callee pushes `lr` inside its own frame, which the frame
  diagnostic counts (`push.w {r4-r11, lr}` + `sub sp, #100` for a frame
  reported as 136). The frame canary reads 4104 there (3968 on x86-64).
- The D1 probe of Task 2 (checked i64 `+ - * / %`, shifts, and the `net.rb`
  bodies) references exactly one undefined symbol, `__aeabi_ldivmod`, from
  the five entries that divide or take a remainder. No multiply, shift, or
  memory helper is referenced. `tests/app/fixtures/cross/d1-helpers.txt`
  holds the list; Task 5 repeats the probe with literals.

- [x] **Build the baseline kernel from `7a7f453`**, record it, and write
  `doom-admission.sh`.
  - Control: the baseline given as both kernels passes.
  - Control: a kernel built with a changed emission flag fails, naming the
    differing object.
- [x] **Measure the `thumbv8m` overhead row** from prologues of the step 2
  fixture, with its evidence sentence.
- [x] **Build the step 2 fixtures for `thumbv8m`.**
  - Two-step emission must be byte-identical to direct emission.
  - The frame canary (the 4096-byte control) must be reported, since the method
    reads an absent diagnostic as a zero frame only after the canary succeeds.
  - The zero-frame fixture must read zero.
- [x] **Gate.**
  - An ARM ELF object with an extra undefined symbol fails with `--extern`
    naming the others, and passes when that symbol is named.
  - Run this on the Mac, where the old host-based rule stripped a character
    from ELF names, and on Debian.
- [x] **Header layout.** A `thumbv8m` header states `ptr32`. A control run
  without `--layout` for a cross target is refused.
- [x] **Spike: clang against Zephyr headers.** Compile a trivial adapter with the
  kernel's clang, using the include paths and defines from
  `compile_commands.json`. Record every rejected flag and its translation. If it
  cannot be done, stop and report: it changes 0014 §1.
- [x] **Create `tools/app/lib/spinel/net.rb`** with `put_u8`, `put_u16`,
  `put_i32`, `put_dec` and `put_str`, written so that every loop has a derived
  bound. `put_dec` is bounded at 20 digits with an early break. The helpers take
  a buffer and a position, which `core-contract 1` already admits. Only
  `put_str`'s literal argument needs Task 5.
- [x] **Preliminary runtime-helper probe (D1).** Build, for `thumbv8m`, through
  `core-contract 1` wrapper entries:
  - checked `i64` `+ - * / %` and shifts with variable and constant operands;
  - the real `put_u8`, `put_u16`, `put_i32` and `put_dec` bodies from
    `net.rb`;
  - `put_str` called with a buffer argument, not a literal.

  List every undefined symbol. If any is not an extern, give the owner the D1
  proposal with the list. Task 5 repeats the probe with literals, and its list
  is the one D1 finally rests on.
- [x] **Run the DOOM admission check.**

**Admission:** the baseline build is preparation. `cross.sh` and the admission
check are estimated at 7 minutes in total.

## Task 3: The application contract and admission in the kernel

**Files:**

- Modify `lib/Core/Boundary.cpp` and `include/spinel-mlir/Core/Boundary.h`.
- Modify `lib/Core/Eligibility.cpp` and `include/spinel-mlir/Core/Eligibility.h`.
- Create `tests/app/contract.sh` and `tests/app/fixtures/contract/`.

**Interfaces:**

- `BufferParam` gains `constCount` (a `uint64_t`) and `cross`.
- `Contract` gains `context` and `std::vector<ExternDecl>`:

  ```cpp
  struct ExternArg {
    std::string name;
    Param::Kind kind;
    ScalarDomain scalar;
    ElementType element;
    AccessMode mode;
  };
  struct Guard {
    std::string lhs, op, rhs;
    Status onFalse;
  };  // run time; operands as written
  struct StaticRequirement {
    std::string lhs, op, rhs;
    std::string diagnostic;
  };  // build time
  struct ExternDecl {
    std::string module, fn, symbol;
    std::vector<ExternArg> args;
    std::optional<ScalarDomain> returns;
    bool isrOk;
    std::vector<Guard> guards;
    std::vector<StaticRequirement> statics;
    std::string bound;
    std::string evidencePath;
  };
  ```

- **Eligibility admits:**
  - a `CallNode` whose receiver is a `ConstantReadNode` naming a declared
    extern's module, with a matching `fn` and arity;
  - a `StringNode` only as an argument for an `in` `u8` buffer parameter, of a
    helper or an extern.
- **Refusal codes:**
  - `extern-context`: a non-`isr_ok` extern called in interrupt context;
  - `cross-to-extern`: a cross buffer passed to an extern;
  - `extern-arity`, `extern-domain`, `extern-mode`;
  - `writes-on-in`: a buffer written by an extern whose argument is `in`;
  - `literal-position`: a string literal anywhere else;
  - `loop-unbounded`: an application entry with a loop whose bound is not
    derived;
  - the diagnostic named by a `static` requirement that is false at a call
    site (for channels, `channel-buffer`);
  - `guards-in-source`: a `guards:` or `statics:` keyword in application
    source.

- [x] **Spike first.** Find how the pinned reader represents `Adc.latest(0)` in
  two forms: when the module is declared only by `core_extern`, and when it has
  a generated stub `def self.latest(ch) = 0`. Choose the form that gives the
  checker a resolvable `CallNode` without reader type errors, and record the
  evidence. Packaging in Task 6 follows the choice.
  - *Chosen (2026-09-22): declarations only, no stub.* In both forms the
    reader gives the same `CallNode` with a `ConstantReadNode` receiver and
    no error; the stub only adds producer types the kernel does not use under
    facts, and is not found as a helper (a `def self.` inside a module is not
    a top-level definition). The checker resolves the call against the
    contract's `extern` lines by module, function and arity before the
    integer-constant and helper lookups that refused it before.
  - *Measured with it, and binding on Task 6:* **the kernel's snapshot must
    hold no `core_extern` declarations** (an empty `module X; end`, or no
    module at all): the pinned analyser treats a call named `send` as Ruby's
    dynamic dispatch and synthesises candidate `CallNode`s from every string
    literal in the calling method and from the declaration's keyword symbols;
    those nodes are absent from the AST and the reader refuses the file
    (`dangling-reference`). With empty modules the file is clean unless a
    method both calls `X.send(...)` and holds a string literal, which is why
    the channel method names are the owner's decision recorded under "Owner
    decisions" (D4). Task 3's fixtures use the proposed `put`/`get`.
- [x] **Parser fixtures:**
  - one accepted v2 contract;
  - one refusal per malformed line kind;
  - v1 with an `extern` line;
  - v2 without `context`;
  - a malformed `guard` line and a malformed `static` line.
- [x] **Eligibility fixtures:**
  - one per refusal code, each input kept, including `writes-on-in` expressed as
    an `inout` extern argument passed a literal or an `in` buffer;
  - accepted calls in thread context and in interrupt context;
  - a literal passed to a helper, and a literal passed to an extern.
- [x] **Derived bounds.** An application entry with an unknown loop is refused,
  in thread context and in interrupt context. The same loop in a v1 contract is
  still reported, under `hosted-stage2`.
- [x] **Run the DOOM admission check.**

**Admission:** `contract.sh` plus the admission check, estimated at 7 minutes.

## Task 4: Effects, call counts, evidence and the v2 report

**Files:**

- Create `lib/Core/Effects.cpp` and `include/spinel-mlir/Core/Effects.h`.
- Modify:
  - `lib/Core/Eligibility.cpp`: call edges, as 0013 item 7 recommends;
  - `lib/Core/LoopBounds.cpp`;
  - `lib/Core/Report.cpp`;
  - `lib/Core/StackBudget.cpp`: extern stack from bound evidence.
- Create `tools/mlir/native/schema/core-report-v2.schema.json`.
- Modify `tests/core-report/run.sh`: v2 schema validation.
- Create `tests/app/effects.sh` and its fixtures.

**Interfaces:**

- `EligibilityReport` gains `std::vector<CallEdge>`, where
  `CallEdge {caller, callee, nodeId, externIndex}` and `externIndex` is −1 for
  helper calls.
- `Effects.h`:

  ```cpp
  struct ExternUse {
    size_t externIndex;
    std::string callsExpr;
    bool derived;
  };
  struct EntryEffects {
    std::map<std::string, bool> bufferWritten;
    std::vector<ExternUse> externs;
  };
  EntryEffects deriveEffects(const EligibilityReport &,
                             const LoopBoundsReport &,
                             const Contract &);
  ```

- **The kernel option `--config-binding <dts>:<config>:<flags>`** is required
  for v2 contracts. The kernel reads extern evidence files and accepts one only
  under the binding rule of the Interfaces section.
  - *Fixed in Task 4 (2026-09-22).* The evidence path of an `extern` line is
    resolved relative to the contract file. `--config-binding` is required
    for every v2 report and refused when it is not three lowercase sha256
    digests. The kernel derives the per-extern call count in the loop
    analysis (`ExternTerm`, `ExternCount`: a site's count is its occurrence
    multiplier, and an extern's is the sum over its sites), the write set
    as a fixpoint over the closure (`Effects.cpp`), and on the stack budget a
    declared callee's frame comes from the bound evidence as an
    `attestation`, or the path has no answer (`spinel-core-stack --attested
    <symbol>=<bytes>` is the fixture form).
  - **The admission-only report** (an addition to "Interfaces", made here):
    `--admit-only --report <json> --profile <p> --config-binding <b>` writes a
    v2 report for an entry nothing has lowered yet -- Task 4 lands before
    Task 5 -- with `"object": null` and `stack_budget` and
    `undefined_symbols` unevaluated, each with its reason. Everything the
    `application` object holds is already final. A full build writes the
    same document with the object. The v2 schema admits both.

- [x] **Write-set fixtures:**
  - a direct write;
  - a write through a helper parameter;
  - a write through an `inout` extern argument;
  - a read-only use.
- [x] **Call-count fixtures** (expected counts):
  - two sequential calls: 2;
  - loops of 2 and 3 in sequence: 5;
  - a call in a loop of 3 inside a helper called twice: 6;
  - a call in each arm of a conditional: 2.
- [x] **Evidence fixtures:**
  - evidence of 24 bytes adds exactly 24 to the path, as `attestation`;
  - evidence that is missing, for another target, or bound to a different
    `.config` digest makes the verdict `unknown`, each with a named reason.
- [x] **Reports.** v2 reports validate against the v2 schema. v1 contracts still
  write v1, and the three existing goldens are unchanged.
- [x] **Run the DOOM admission check.**

**Admission:** `effects.sh` plus the admission check, estimated at 8 minutes.
`tests/core-report/run.sh` in full is carried to the final verification.

## Task 5: Lowering

**Files:**

- Modify `lib/Frontend/Scalar/Importer.cpp` and `MlirGen.cpp`.
- Modify `lib/Core/Kernel.cpp`: the v2 signature and the guard checks.
- Modify `lib/Core/Boundary.cpp`: v2 entry headers and the extern prototype
  header.
- Create `tests/app/lowering.sh`, and a native C harness under
  `tests/app/fixtures/lowering/`.

**Interfaces:**

- An extern becomes `llvm.func @<c_symbol>`, with the C ABI of the Interfaces
  section: a buffer is a pointer followed by a `u32` count.
- Guards are emitted before the call, in declared order. A false guard returns
  its status, and the extern is not called. A guard that is false for constant
  operands becomes an unconditional failure at that call site, never a build
  refusal.
- A literal becomes a private constant `[N x i8]` global. Its address and `N`
  are passed.
- **The atomic closure.** Every buffer access in any helper reachable with a
  `cross` argument, and every access through a `cross` entry parameter, is an
  atomic `monotonic` load or store with element alignment. Accesses outside that
  closure are plain.
  - *Fixed in Task 5 (2026-09-22).* The checker's borrow facts carry `cross`
    (joined as OR through the calls that reach a helper), the importer marks
    every buffer of a helper atomic when any of its borrows is cross, and the
    entry's own cross parameters are atomic. On thumbv8m a `u8` cross copy is
    one `LDRB` and one `STRB` per element; an `i64` cross buffer is refused
    for a 32-bit target (`cross-i64`), since no single instruction accesses
    64 bits atomically there.
  - *Also fixed.* An application's helpers are shared by its entries, so the
    v1 ingress rule (another top-level definition calling into the closure
    is refused) does not apply to an application: each entry is its own
    closure under its own contract, in its own object. Any empty module, or
    one holding only `core_extern` declarations, is admitted at top level,
    not only the modules this entry's contract declares.
  - *The C ABI as lowered.* A scalar argument is range-checked into its
    domain (a value outside `i32`/`u32` is `ARITHMETIC`, never truncated); a
    buffer's count is passed as `u32` from the constant or the caller's
    descriptor; a `void` extern in statement position lowers to a call with
    no value. A constant-false guard folds to an unconditional failure at
    its site and the call disappears from the object (`send_zero`); a guard
    under an untaken branch folds away with the branch (`untaken`).
  - *Relocations.* `tests/doom-core/object-relocs.rb` now knows Thumb:
    `R_ARM_THM_CALL` is a branch, a `MOVW/MOVT` pair is an address pair, and
    `R_ARM_PREL31` from `.ARM.exidx` to `.text` is a self-reference; `--extern
    SYM` admits a branch to a declared extern or a D1 helper, by exact name.
    A data reference to an undefined symbol is still refused.

- [x] **The optimised IR shows:**
  - atomics exactly on the atomic closure, including a helper reached with one
    cross argument and one private argument, where both are atomic;
  - no atomics outside the closure;
  - one declaration per extern;
  - guard branches before each extern call.
- [x] **Built for `thumbv8m`:**
  - the undefined set equals the declared externs, by the gate with `--extern`;
  - each cross access is one `LDR`, `LDRB`, `STR` or `STRB` of the element
    width, with no `LDRD`, `LDM`, `STRD` or `STM`, by disassembly;
  - literal bytes are in the object's own read-only data, and the 0010
    relocation rule passes.
- [x] **ABI fixtures**, native on both hosts: a host-built application object
  linked with C providers compiled against the generated prototype header.
  - A literal passed to a provider: the provider receives the bytes and the
    length.
  - A state buffer passed to a provider: the pointer and the constant count.
  - A provider whose definition drops the `_len` parameter fails to compile.
  - Each guard failure returns its status, and the provider records no call.
  - `send(buf, 0)` with a constant `0`, and `send(buf, n)` with `n` read from
    state, each return `ARGUMENT` at run time. Effects before the call remain.
  - A constant-invalid `send` on an untaken path builds, and runs to `OK`.
- [x] **Final runtime-helper probe (D1).** Repeat Task 2's probe with `put_str`
  called with string literals, now that literals lower. Its undefined-symbol list
  is the one D1 rests on. A helper that is not an extern, with D1 undecided,
  stops the gate work on that object, and it is reported.
- [x] **Out-of-bounds writes.** An application write past a state buffer's end,
  including through `put_str` and `put_dec` into a short buffer, returns
  `BOUNDS`. Guard canaries on both sides of the buffer stay untouched.
- [x] **Controls:**
  - an `i64` cross buffer on `thumbv8m` is refused;
  - a cross buffer passed to an extern is refused by Task 3's code, and not
    lowered.
- [x] **Run the DOOM admission check.**

**Admission:** `lowering.sh` plus the admission check, estimated at 9 minutes.

## Task 6: Declarations, packaging, cross-entry checks and the host runner

**Files:**

- Create `tools/app/lib/spinel/core.rb`. `net.rb` exists from Task 2.
- Create
  `tools/app/lib/core_app/{app_model,declarations,channels,contracts,app_checks,host_runner}.rb`.
- Create `tools/app/bin/spinel-core-app`, with `run-host`.
- Create `tests/app/host.sh` and `tests/app/fixtures/apps/`.

**Interfaces:**

- `CoreApp::Declarations.read(path) -> App`.
- `CoreApp::Channels.generate(app) -> ChannelPackage`: Ruby modules, C source
  and host simulators.
- `CoreApp::Contracts.write(app, board, channels, dir) -> {entry => path}`.
- `CoreApp::AppChecks.run(app, board, channels, reports) -> [Diagnostic]`,
  with codes:
  - `shared-writer`;
  - `device-owner`;
  - `channel-end`;
  - `channel-buffer`;
  - `unknown-member`;
  - `member-effect`: `isr_ok` in interrupt context, or a member that is
    blocking, or of unknown blocking, called under `realtime`;
  - `declaration`.
- `CoreApp::HostRunner.run(app, board_host, channels_host, stimulus) -> Trace`.
  - It emits the Interfaces trace kinds.
  - **Virtual time.** Executing an invocation advances the clock by that
    invocation's `cost` (0 when none is given). When nothing is executing, the
    clock jumps to the next event: a release, a stimulus item, `H`, or the drain
    deadline. `cost` is execution time, and idle time is the jump.
- **Tests before Tasks 7 and 8 exist** use a synthetic board package
  (`tests/app/fixtures/synthetic-board/`, with `board.rb`, `board_host.rb` and
  `board.tsv`) and the channel simulators. Task 7 and Task 11 re-run the host
  fixtures against the real generated packages.

- [x] **`spinel/net.rb` control.** A variant of `put_dec` that loops while the
  value is non-zero is kept as a refused control, under application rules.
  (`tests/app/fixtures/apps/net-unbounded/`, refused as `loop-unbounded`.)
- [x] **Packaging.** The packaged root holds `app.rb`, `spinel/net.rb`, and the
  board and channel declarations, in the form chosen by Task 3's spike, as one
  file with a recorded digest. Reuse the 0008 source-pack approach.
  (`CoreApp::Contracts.pack`: the approach -- units read once, digested,
  joined by a newline only, a line map -- and not `tools/doom/pack-core.rb`
  itself, whose rules refuse the top-level declaration calls an application
  consists of. The application's `require` lines become comments on the same
  line, because the pinned analyser refuses a `require` it cannot satisfy;
  the map records the source unit's digest.)
- [x] **Cross-entry checks.** One fixture per diagnostic code, each with its
  input kept, plus an accepted multi-context application. Also: an entry named
  by two triggers, and a trigger naming no entry.
  (The device-owner check needs each call site's instance index, which the
  version 2 report did not carry: it now has `const_args` per extern, one
  array per source call site with the constant scalar arguments; the schema
  and `docs/core/core-report.md` record it. `member-effect` for `isr_ok` is
  raised by the tool at the reference, and by the kernel as `extern-context`
  through a helper; both land on the same fixture.)
- [x] **Host runner.**
  - Scheduling, selection and skips follow 0014 §4.
  - Checked domains use the checked-operand mechanism of
    `tests/core-boundary/oracle.rb`. If it moves into `tools/app/lib`,
    `oracle.rb` and its six mutation controls stay unchanged and passing.
    (Copied into `tools/app/lib/core_app/checked.rb`, operator for operator;
    `oracle.rb` is untouched. The transport thread drains `:out` channels
    whenever the scheduler thread is idle, at no cost, and not inside an
    invocation's cost window. Devices' safe states on failure are the
    target glue's, Task 10, and are not simulated.)
  - Channels follow 0014 §5, including the two inbound drop reasons.
  - Terminal classes at the horizon.
- [x] **Idle time.** A run with periodic releases, gaps between them, and no
  `cost` lines processes every release, and reaches `H` and the end marker.
- [x] **Host scheduling fixtures,** driven by `cost` (plus a horizon cut):
  - a self-overrun with the right skipped releases;
  - a cross-entry delay;
  - several missed releases;
  - two entries due together where the first ends before the second's next
    release: no skip;
  - a context failure whose remaining releases are `CANCEL` records linked to
    its `FAIL`.

**Admission:** `host.sh`, estimated at 3 minutes (measured 13 s on Debian).

Added in Task 6, after the third Mach-O underscore defect (the macOS coordinator's
rule for Tasks 6-13): every check that reads symbol names from an object
goes through `tools/core/object-symbols`, which decides the prefix from the
object's format; `core-artifact-gate` and `tests/app/contract.sh` call it,
and `contract.sh` holds one control per format (Mach-O, ELF, COFF refused).
The rule binds checks added from Task 6 on; the older lanes that parse `nm`
themselves (`tests/app/lowering.sh`, `tests/app/cross.sh`,
`tests/native-core/run.sh`, `tests/doom-core/borrowed-calls.sh`,
`tests/doom-core/verify.sh`, `tests/gc-arena/run.sh`) are not moved here.

## Task 7: Board package generation

**Files:**

- Create `tools/app/lib/core_app/{dts,board,evidence}.rb`.
- Create `tools/app/adapters/{led,button,pwm,adc,clock}/`.
- Create `tools/app/zephyr/<release>/{effects,screen}.tsv`.
- Create `tests/app/board.sh` and `tests/app/fixtures/dts/`.

**Interfaces:**

- `CoreApp::Dts.parse(text) -> Tree`, whose root and nodes have `path`,
  `labels`, `properties` and `children`, with `by_label`, `by_path` and
  `compatibles` on the tree. An unsupported construct is an error naming the
  line. (As implemented in Task 7; the plan first said `-> Node`.)
- `CoreApp::Board.generate(dts:, config:, effects:, adapters:, out:, board:,
  release:, dts_sha256:, config_sha256:, flags_sha256:) -> Package` with
  `modules`, `rows`, `files` and `provenance`; the files are written flat
  into `out` (`board.rb`, `board_host.rb`, `board_port.c`, `board.tsv`,
  `provenance.json`), and the build places them where the packaged root's
  `require "spinel/board"` finds them.
- **Adapters.**
  - `adapter.c` defines `spc_adapter_<class>_<fn>` over a table the generated
    `board_port.c` owns, and `board_port.c` defines `spc_board_<module>_<fn>`
    for each module, split modules included; every function is non-blocking.
    `Adc` samples in a thread of its own, and `latest` reads a word-atomic
    value.
  - `sim.rb` is the simulator template for CRuby (`%MODULE%`, `%COUNT%`); a
    split module's copy registers no stimulus handler.
  - `class.tsv` states the devicetree source, the functions and their
    signatures, the safe-state action, and the index guard, which is on
    (D2 was approved before this task: `guard index < COUNT else bounds`).
    Task 10 added two keys: `subsystem`, the Kconfig symbol the class's
    driver needs, enabled only when an application refers to the class;
    and `glue`, a C unit beside the adapter that the build compiles,
    measures, links and screens but for the block set (the Adc sampler
    thread); and, after Task 11, `thread`: a thread the glue creates, with
    its unit, stack macro, object, entry, init and reserve items, which the
    build gives a requirement, recompiles with `-D<macro>=R` and reads back.

- [x] **Devicetree fixtures:**
  - the real `mps2/an521` and FRDM-MCXN947 `zephyr.dts` from Task 1, with their
    digests;
  - synthetic DTS for an I2C GPIO expander;
  - synthetic DTS for an unknown driver;
  - synthetic DTS for a class with mixed effects.
  (`tests/app/fixtures/dts/`, with the `.config` of each real build beside
  its DTS, since the effect table's `applies_when` reads it.)
- [x] **Generated modules.**
  - Counts and names equal the devicetree.
  - The expander instance is not `isr_ok` and is split into its own module.
  - The unknown driver is not `isr_ok` and is not proven non-blocking.
  - `board.tsv` names every node.
  (Three points settled in the implementation. Constants are written in
  their own module, `Led::COUNT`, `Led::LED0`, `Led::USERLED0`; the packed
  root carries each module with its own constants in its body. (Task 7 first
  wrote them at top level with a module prefix, because the checked boundary
  then resolved only top-level integer constants; D5 moved them, and the
  kernel resolves `Mod::NAME`.) A device is the controller channel, `board.tsv`'s `node_path` is
  `<controller path>:<channel>`, so two LEDs on one GPIO controller are two
  devices and two instances on one pin are one, as 0014 §4 says. The index
  guard is on: D2 was approved before this task, so `guard index < COUNT
  else bounds` is emitted for every member taking `index`, and the
  "disabled until D2" of the adapter interface no longer applies.)
- [x] **Screen**, one kept control each: an adapter object calling `k_malloc`,
  one calling `k_sleep`, one calling `irq_connect_dynamic`, and one calling an
  entry symbol.
- [x] **Resolution.** A member only one board has resolves there, and gives
  `unknown-member` on the other.
- [x] **Re-run Task 6's host fixtures** against the generated packages for
  both boards.
  (The seven scheduling and channel fixtures, which name no board member, on
  both real boards, plus `tests/app/fixtures/boards/leds`, which names
  members by alias constants and drives a different instance on each board.
  `accepted` and the code fixtures name the synthetic board's members and
  stay on it.)

**Admission:** `board.sh`, estimated at 3 minutes, without Zephyr configure
time (measured 6 s on Debian). The adapters' C and every generated
`board_port.c` are parsed with `clang -fsyntax-only` against stand-in headers,
which establishes well-formed C and nothing about Zephyr's API; compiling
them against Zephyr v4.4.2 needs a configured build's generated headers and
is Task 10's pipeline. Provider evidence files (`CoreApp::Evidence.write`,
`read`, `bound?`) are checked in isolation here; the build that writes them
is Task 10's. `Clock` is generated for both boards and no fixture calls it.
The effect rows for `zephyr,gpio-emul` and `zephyr,adc-emul` are exercised by
no fixture until the verification build (Task 11).

## Task 8: Channels, the UART transport and byte helpers

**Files:**

- Create `tools/app/templates/{channel.c.erb,channel.h.erb,transport_uart.c.erb}`.
- Complete `lib/core_app/channels.rb`.
- Create `tests/app/channel.sh` and `tests/app/fixtures/channel/`.

**Interfaces:**

- `spc_channel_<name>_put(const uint8_t *data, uint32_t data_len, uint32_t n) -> int32_t`
  returns 1 or 0.
- `spc_channel_<name>_get(uint8_t *data, uint32_t data_len) -> int32_t` returns
  the length or 0.
  (The plan first wrote `spc_ch_<name>_send/recv`; Tasks 3 to 6 fixed the
  symbol rule `spc_<origin>_<module>_<fn>` and the names of D4,
  so these are the names, and the labels below follow them with `put`/`get`.
  The same function serves both ends: CORE and the transport each call the
  operation that is theirs.)
- Head and tail are C11 `_Atomic uint32_t`. Publication follows 0014 §5, with
  `memory_order_release` and `memory_order_acquire`.
- **The copy and publication spans are labelled per channel and per
  operation.**
  - They are delimited by `asm volatile` global labels named
    `spc_ring_<channel>_<put|get>_<copy|pub>_<begin|end>`.
  - Each labelled function is `__attribute__((noinline))`, in its own
    translation unit, built without link-time optimisation. `noclone` is not
    used: the pinned Clang does not recognise it, and warns that it is ignored.
  - The labels are assembler labels declared `.globl`. So any duplication of a
    labelled body, whether by inlining, cloning or specialisation, emits the
    same label twice, which the assembler or linker rejects. A duplicated body
    is a build error, never a silent miscount.
  - The linked-image check then confirms each label exactly once, inside the
    function that the channel's call sites call.
  - The labels are part of the production source, so Task 12 measures the
    production primitive, under the same scheme.
- **Two-channel fixture.** A two-channel application links. Every label is
  present once in its symbol table, and every begin label precedes its end
  label.
- The transport drops inbound messages only as `oversize` or `channel_full`,
  counted per reason.

- [x] **Native, single-threaded ring tests on the host:**
  - wraparound over 10 × `depth`;
  - FIFO order, and no duplicate;
  - full refusal with the ring unchanged;
  - 0 from an empty ring;
  - the guards through the generated Ruby modules, compiled by the
    kernel natively.
- [x] **Byte helpers.** `put_*` compiled as CORE, natively and for `thumbv8m`,
  gives the same bytes as CRuby on a fixed table.
  (The `thumbv8m` half runs the kernel's object under QEMU inside
  `tests/app/fixtures/channel/qemu-probe`, a Zephyr application that links the
  object; it needs the Zephyr environment and is skipped, or fails under
  `REQUIRE_ALL=1`, without it.)
- [x] **Two-channel label fixture,** as specified above, on the host-linked
  image and on the `thumbv8m` link.
  (The `thumbv8m` link uses the SDK's `arm-zephyr-eabi-ld`, the linker the
  Zephyr build uses; the official LLVM 23.1.1's `ld.lld` on the Debian host
  cannot load its ICU library and is not used. The fixture's entry
  `arm_main.c` references every CORE entry and the transport so nothing is
  garbage-collected; it is never run.)
- [x] **Transport drop rule.** A mutated transport that drops a message while
  the channel has room is kept as the failing input.
  (A copy of the generated transport, patched by `channel.sh` at the
  delivery line, not a switch in the product; the harness feeds one frame
  per step with the occupancy read before each, which is what makes the
  mutation visible -- a batched feed had let it hide behind a later frame
  that filled the ring. The label check also pins the one ordering the
  labels exist for -- the copy span ends before the publication span
  begins -- with a control that swaps them.)

The transport's framing, fixed here: `0xA5`, channel index (u8), length
(u8, 1..size), payload; both directions; a frame naming an `:out` channel or
an unknown index is a framing error counted apart from the two drop reasons.
The transport unit is one pass, `spc_transport_step()`, driven by the host
harness directly and by a Zephyr thread with a 1 ms sleep between passes;
the UART is reached through `SPC_UART_OUT`/`SPC_UART_IN` (host stubs under
`-DSPC_HOST`, `uart_poll_out`/`uart_poll_in` on the console UART otherwise);
`-DSPC_VERIFY` hands each transport event to the recorder's hooks (Task 11).

**Admission:** `channel.sh`, estimated at 3 minutes (measured 8 s on Debian
with the Zephyr environment, 24 checks; 1.5 s without, 20 checks and 4
skipped). Target-side
channel tests are in Task 11, and concurrency is Task 12. Not established
here: the transport compiled against Zephyr's UART API (the thumbv8m units
are built with the host stubs; Task 10 compiles the Zephyr form).

## Task 9: Attested reserves and driver rows

**Files:**

- Create `tools/app/lib/core_app/reserves.rb`.
- Create `tools/app/zephyr/<release>/{reserves,irq-rows,vector-classes}.tsv`.
- Create `tools/app/zephyr/<release>/reserve-harness/`.
- Create `tests/app/reserves.sh`.

**Interfaces:** a reserve row is an attestation with a justification. It is not
an observed high-water mark. The justification has two parts:

1. **The frame sizes of Zephyr's functions on the path.** They come from the
   pinned Zephyr build with `CONFIG_STACK_USAGE=y`, which produces GCC `.su`
   files, and need no hardware.
2. **The path itself,** traced by hand from the source at the pinned commit and
   recorded as a list of functions with their `.su` entries. Indirect calls on
   the path are resolved from that configuration's driver and device tables,
   and each resolution is recorded.

The reserve is the sum along that path. `applies_when` names the Kconfig
symbols the path depends on.

- [x] **For `mps2/an521` and FRDM-MCXN947,** in production and verification
  configurations, produce these reserves:
  - `thread_switch`;
  - `thread_kernel_calls` (the calls the glue makes);
  - `isr_entry_exit`;
  - `pendsv`;
  - `timer_dispatch`;
  - `uart_calls`, for the transport thread;
  - `guard_area`;
  - one reserve per driver interrupt handler in each board's inventory.
  (`tools/app/zephyr/v4.4.2/reserves.tsv`, 20 rows -- the eight items,
  `svc` added because §9 lists the SVC exception among the sources and its
  only path here is the terminal runtime exception, 8 bytes of entry push --
  each with its path under `reserve-harness/paths/<board>/<item>.tsv`. The
  Zephyr paths are the same under both configurations, so one row per board
  serves both, and each row's `applies_when` is derived from its path: the
  symbols whose setting would add or remove a call or a push on it, read
  from the functions' sources (`CONFIG_TIMESLICING=y`,
  `CONFIG_TIMESLICE_PER_THREAD=n` and the 64-bit cycle counter for
  `timer_dispatch`; `CONFIG_STACK_SENTINEL=n`, `CONFIG_TRACING_ISR=n`,
  `CONFIG_PM=n` for the interrupt entry; the driver symbols for the handler
  rows; `=n` for the FPU, the MPU stack guard, userspace and the switch
  instrumentation). Two findings from the harness while writing them:
  the deepest branch of the timer dispatch is not the k_timer handler but
  the time-slice reset -- `z_time_slice` -> `z_reset_time_slice` ->
  `z_add_timeout` -> `sys_clock_set_timeout`, 144 bytes on the interrupt
  stack where the handler branch is 96 -- and the SysTick handler's own
  frame doubles with the 64-bit cycle counter on (8 to 16). Both are in the
  path notes.)
- [x] **Write `irq-rows.tsv`** for every driver that the two configurations
  enable, and `vector-classes.tsv` for the pinned release: reset, terminal
  (NMI and the faults) and the default and spurious handlers.
  (11 irq rows: the eight compatibles of `effects.tsv` plus the console
  UART drivers `arm,cmsdk-uart`, `nxp,lp-flexcomm` and `nxp,lpuart`;
  `vector-classes.tsv` lists the debug monitor with the faults as terminal,
  and `_isr_wrapper` with the spurious handlers as default: with
  `CONFIG_GEN_IRQ_VECTOR_TABLE=y` every IRQ slot points at it and the
  software table decides, so Task 10's slot classification consults
  `_sw_isr_table` for an `_isr_wrapper` slot.)
- [x] **Falsification harness,** a non-deliverable QEMU app for `mps2/an521`.
  It paints the stacks, drives each reserved path, and fails if any high-water
  mark exceeds its reserve. Its result is recorded as falsification evidence,
  never as the reserve.
  (`reserve-harness/`; its first run refuted the first `timer_dispatch`
  reserve, 136 bytes against 96, which is how the time-slice branch was
  found. The harness repaints the interrupt stack itself before it drives
  the paths, so the mark is the run's and not the boot's. What it drives
  and what it cannot refute -- the `isr_<driver>` rows, the `thread_switch`
  frame at the mark, `svc`, and nesting -- is stated in its README; the
  `CONFIG_TIMESLICING=n` control shows the slice branch is the one that
  raises the interrupt-stack mark.)
- [x] **Controls:**
  - a row whose `applies_when` does not hold for the build is ignored, and the
    verdict becomes `unknown`;
  - a harness run with one reserve deliberately lowered below the path must
    fail.

**Admission:** `reserves.sh` (applicability logic and the controls), estimated
at 3 minutes. The `.su` builds are preparation. The QEMU harness run is carried
to the final verification if it does not fit. (Measured on Debian: 46 s,
33 checks, with the Zephyr environment, the four `.su` builds and four QEMU
runs included; 0.4 s, 12 checks and 22 skipped, without. Every applicable row whose path has `.su`
steps is recomputed from the fresh `.su` files on every run; the four
literal-only rows per board -- `thread_switch`, `pendsv`, `svc`,
`guard_area`, read from the source -- are named as not recomputable. Task
10 added the `drv_<member>` rows per board and the an521 GPIO ISR row, 30
rows in all; `drv_adc_latest`, an inline atomic read, is the fifth
literal-only row.)

## Task 10: Glue, the build pipeline, stacks and the inventory

**Files:**

- Create `tools/app/lib/core_app/{glue,pipeline,stack,inventory}.rb`.
- Create templates for `main.c`, the scheduler, timer dispatch, the failure
  handler, `CMakeLists.txt`, `prj.conf` and the overlay.
- Complete `spinel-core-app build`.
- Create `tests/app/build.sh` and its fixtures.

**Interfaces:**

- **The pipeline** implements 0014 §8's eleven steps. Staging is
  `<out>/.staging`. Publication renames `firmware`, only after step 10 passes.
  Any failure removes staging (`--keep-staging`, a diagnostic option, keeps
  it after a refusal; firmware is never left). The published `firmware/`
  holds the image, the map and link log, the DTS and `.config`, the
  evidence with the measured objects it names, the reports, the board
  package, `main.c` and `build.json` (the stack verdicts with their terms,
  the inventory, the vector-slot classes, the memory figures).
- **The scheduler, timer dispatch and failure handler** follow 0014 §4. They use
  the clock chosen in Task 1, and the safe-state actions from `class.tsv`.
- `CoreApp::Stack.check(glue:, transport:, entries:, reserves:, inventory:, board:, config:) -> Verdicts`
  (as built: the glue and transport frames from the `.su` files, the
  entries' `kernel_stack` from the reports, the applicable reserves).
  It reports `R`, the feasibility gates and the interrupt inequality
  separately, for the scheduler thread, the transport thread (when the
  application declares a channel) and the interrupt stack.
- `CoreApp::Inventory.build(dts, config, irq_rows, board:) -> Result`
  (`sources`, `absent`, `unknown`).
- `CoreApp::Inventory.classify_vectors(elf, inventory, vector_classes, config, symbols_tool:, objcopy:) -> [[Slot], [failure]]`
  sorts slots into the five classes, after word 0.

- [x] **Build the acceptance sample** for `mps2/an521`, with the step 10 checks
  and the reports.
  (`tests/app/fixtures/build/sample` with `mps2_an521.overlay`; R(scheduler)
  316, R(transport) 236, interrupt chain 312 of `CONFIG_ISR_STACK_SIZE`
  4096, 111 vector slots classified as reset 1, terminal 7, reserved 4,
  budgeted 17, unused 82; data + bss 9,911 of the board's 4,194,304 bytes;
  11 s on Debian. Under QEMU the image prints `SPC_RUNNING`, no failure,
  and streams telemetry frames. What building it settled, each recorded in
  the code: the transport thread and the Adc sampler thread are glue of §4
  -- compiled, measured and linked, and screened for everything but the
  block set, since a thread of §4 legitimately sleeps but may not allocate,
  reconfigure interrupts or call back into CORE (the glue-irq control found
  that `irq_disable()` on Cortex-M expands to `arm_irq_disable`, which
  `screen.tsv` did not list; the Cortex-M spellings are listed now); the
  Adc sampler thread the adapter's glue creates had, at Task 10, a literal
  stack and no requirement, and the item below closed it inside this
  milestone; the kernel's own stack inequality has no right-hand
  side under `realtime` by design (the provision is R, which step 8 derives
  from that very `kernel_stack`), so step 7 accepts exactly that `unknown`
  and no other; clang inlines the entry wrappers and the failure handler
  into the loop, so each thread's glue term is the sum of the frames over
  its call tree, which bounds every path under any inlining; the requested
  stack size is recorded as a word the glue reads at thread creation and
  step 10 reads back from the image, because `K_THREAD_STACK_DEFINE`
  rounds the object to the 8-byte stack alignment and the object's size
  alone cannot tell R from R − 1; a driver subsystem is enabled only when
  the application refers to a class that needs it (`class.tsv`
  `subsystem`), since an unused driver still connects its interrupts and
  every connected interrupt needs an attested reserve; the memory figures
  are read from the section table by flag -- writable and NOBITS in RAM,
  read-only in flash -- and agree with `llvm-size`.)
- [x] **FRDM-MCXN947.** Build the same source for FRDM-MCXN947. If Task 1 found
  `pwm-leds` there, also build the `Pwm` sample, and report whether that
  condition held.
  (Builds with `frdm_mcxn947.overlay`, which adds the two `zephyr,user`
  LPADC channels in the shape of Zephyr's own `adc_api` overlay for the
  board: R(scheduler) 316, R(transport) 252, chain 252 of 2048, 171 slots
  classified with 16 budgeted, data + bss 8,015 of 327,680; 15 s. The condition did not hold: the
  pinned devicetree has no `pwm-leds`, so no `Pwm` build was made. Its
  `CONFIG_HW_STACK_PROTECTION=y` does not select `CONFIG_MPU_STACK_GUARD`
  in this configuration, so the plain stack-object rule holds there; a
  guard or userspace changes the object's layout and is refused at step
  10, and Task 9's `guard_area` row applies only without the guard.)
- [x] **Controls,** each input kept:
  - a thread stack allocation altered to `R − 1` is refused at step 10;
  - `CONFIG_ISR_STACK_SIZE` below the requirement is refused at step 8;
  - `CONFIG_FPU=y` is refused;
  - an extra connected handler is refused;
  - a non-zero reserved vector slot is refused;
  - a driver without an `irq-rows` entry gives `unknown`, and a failed build;
  - a `.config` changed between steps 3 and 9 is refused;
  - a period that the tick rate cannot represent is refused, naming the rate;
  - a `core_extern` provider calling a screened symbol is refused at step 5;
  - an accepted application provider is compiled, measured and linked, and its
    stack is reported;
  - a failure at step 7 leaves no `<out>/firmware`.
  - added by the preflight: a linked unit that was never measured is
    refused at step 10 (§8: the objects linked are the ones measured); a
    glue unit that disables an interrupt, and one that calls an entry, are
    refused at step 5.
  (`tests/app/build.sh` runs all thirteen with their own builds; the inputs are
  the fixtures under `tests/app/fixtures/build/` and the `--mutate-*`
  options of `spinel-core-app build`, each of which plants one input where
  the plan says it is refused. The FPU control runs on FRDM-MCXN947, which
  has an FPU; on `mps2/an521`, which has none, Kconfig drops
  `CONFIG_FPU=y` and the `.config` never carries it. The extra handler
  connects IRQ 90, used by no device of the an521 devicetree -- IRQ 40,
  tried first, is the console UART's and Zephyr's own table generator
  refuses the double registration. The `.config` control changes a value
  (`CONFIG_MAIN_STACK_SIZE`), since a comment appended to `.config` is
  regenerated away by the link's Kconfig pass and would not be a change.)
- [x] **The Adc sampler thread's stack** (the macOS coordinator's ruling,
  2026-09-23; after Task 11 lands, before Task 13). `adapters/adc/sampler.c`
  creates a thread with a literal 1024-byte stack that blocks in the ADC
  driver's read (`adc_read_dt`) and sleeps; its own frames are measured
  (`build.json` `threads_unbudgeted`), but the Zephyr driver path it blocks
  in has no attested reserve on either board, so the thread has no R and
  enters neither inequality of §9. It is not deferred to the final
  verification: the milestone's claim is that the generated firmware's
  stacks are checked, the acceptance configuration includes Adc, and a
  thread our own glue creates outside the inequalities is a hole in that
  claim, not a long-running check. What closes it: a Task 9-style attested
  path over the driver's read path per board (`reserve-harness/paths/
  <board>/adc_read.tsv` over the driver's `.su` frames: `adc-emul` on
  an521, `lpadc` on FRDM), then the transport's treatment -- a requirement,
  the recorded size word and its step-10 readback, and the R − 1 control.
  If a board's path cannot be attested, no number is invented: the obstacle
  is reported and refusing Adc on that board is considered instead.
  (Done, 2026-09-23. The path is `drv_adc_read`, attested per board from
  the harness's `.su` frames: on an521 `adc_emul_read` 32 + `z_impl_k_sem_take`
  16 + `z_pend_curr` 24 = 72, the wait for completion being the deepest
  branch (the read's inlines, the lock's `k_sem_take` shallower); on FRDM
  `mcux_lpadc_read` 56 + 16 + 24 = 96. Both could be attested; the harness
  gained `boards/mps2_an521_cpu0.overlay` with the acceptance configuration's
  `adc-emul` node so `adc_emul.c` is built with frames; `reserves.tsv` is
  32 rows and `reserves.sh` recomputes both. The thread now has the
  transport's treatment: `class.tsv`'s `thread` row names the unit, the
  stack macro, the object, the entry, the init that runs elsewhere and the
  reserve items; `Stack.check` builds `adc_sampler thread` = the unit's
  frames but the init (32) + `drv_adc_read` (72) + `thread_kernel_calls`
  (128, the sleep; the two blocking paths are alternatives, summed, which
  bounds either) + `guard_area` + `thread_switch` = 268 on an521; step 8
  recompiles the unit with `-DSPC_ADC_STACK=R` and refuses a changed
  frame, step 10 reads `spc_adc_stack` and `spc_adc_stack_size` back, and
  `build.sh` refuses R − 1 (`--mutate-adapter-stack -1`). The
  verification run prints and checks its mark: 180 of the verification
  build's 284. A production build's `threads_unbudgeted` is empty and
  stays a field so the claim reads as total for that build; a
  verification build lists the one thread that still has a literal stack,
  the stimulus thread its own glue creates, which exists to drive the run
  and is not part of what a production image claims. The requirement's
  two driver reserves are alternative blocking paths, summed so the
  requirement bounds whichever the thread is in, and the terms in
  `build.json` say so; the init's frame is excluded because it runs on
  Zephyr's main thread, whose stack no inequality bounds (the honest
  boundary above), and `adapter_threads` publishes it rather than
  dropping it. Beside it, the control the macOS coordinator asked for
  after the Task 11 preflight: a reserves table without the an521 GPIO
  ISR row (`--mutate-reserves`) is refused at step 6, the refusal that
  had been clobbered and that no suite named.)
- [x] **The 16 interrupt-stack bytes the Task 9 harness does not explain**
  (the macOS coordinator's ruling, 2026-09-23: out of the final verification, next
  to the sampler item, after Task 11 and before Task 13 -- because of the
  method, not the margin). Observation (Debian, 2026-09-23, `REQUIRE_ALL=1
  sh tests/app/reserves.sh`): the `mps2/an521` production run marks the
  interrupt stack at 136 bytes; the same harness built with
  `-DCONFIG_TIMESLICING=n` marks 112 (its worker thread 160 against 168
  with slicing; the Mac measured the same four values), while the k_timer
  branch of `timer_dispatch` sums to 96 (`sys_clock_isr` 16 +
  `sys_clock_announce_locked` 32 + `z_timer_expiration_handler` 24 +
  `z_ready_thread` 8 + `ready_thread` 16; the prologues in the image equal
  the `.su` frames). Two candidate explanations, and they differ in what
  they say about the method every row of `reserves.tsv` rests on: (1) a
  SysTick entry taken while PendSV is active, whose hardware frame (32
  bytes plus alignment) lands on the interrupt stack -- the nested-entry
  term of §9's inequality, which Task 10 carries explicitly; then the
  `.su`-sum method is sound and the term covers the bytes. (2) The residual
  is inside the handler path itself, invisible to the `.su` frames; then a
  path's true cost exceeds its `.su` sum by 16 bytes on the one path with a
  mark to compare, and every other row -- other boards, other
  configurations, the ones with no QEMU run behind them -- is optimistic
  by an unknown amount, which is a fact about the table, not a margin. The
  run must distinguish the two, with the predictions stated beforehand, as
  for the `timer_dispatch` refutation: one run forces the nesting (a thread
  that pends PendSV by yielding in a loop while a 1 ms timer expires) and
  one excludes it (the timer expiring only while the worker spins with the
  scheduler lock held, so no PendSV is pending), the interrupt-stack mark
  read after each, slicing off. Predictions: under (1) the excluded run
  marks 96 and the forced run at most 96 + 36 = 132; under (2) the excluded
  run still marks 112, the forced run at most 112 + 36. Outcome (2) stops
  the work: the fix is a method change, the macOS coordinator's and the owner's to
  decide, not a bigger number.
  (Done, 2026-09-23, and NEITHER prediction held. The probe is
  `reserve-harness/settle`, kept because this conclusion rests on it; no
  suite runs it. Measured on Debian, `mps2/an521` under QEMU, slicing off:
  the excluded run marks **112**, the forced run **144**, and a third run
  of the excluded mode with one measurement inside the expiry callback
  puts **73** bytes below the callback and marks 112 again.
  Forced − excluded is **32**, exactly one Cortex-M hardware exception
  frame: nesting is visible to this method when it happens, and the
  excluded run has none of it, so hypothesis (1) does not explain the 112.
  Nor is it hypothesis (2). The branch actually taken is
  `sys_clock_isr` 16 + `sys_clock_announce_locked` 32 +
  `z_timer_expiration_handler` 24 + `z_add_timeout` 40 = **112**, the mark
  exactly -- SysTick has no `_isr_wrapper` frame under
  `CONFIG_CORTEX_M_SYSTICK_INSTALL_ISR=y`, so `isr_entry_exit` is not on
  this path. `z_add_timeout` is a PERIODIC timer re-arming itself, and it
  runs on the ENTRY path, BEFORE the callback (`kernel/timer.c:107` at the
  pin, against `expiry_fn` at `:125`). The 16 bytes were the difference
  between that re-arm (40) and the `z_ready_thread` + `ready_thread` (24)
  the observation above enumerated in its place: 64 − 48 = 16.
  What the callback measurement does and does not say: 73 is what is LIVE
  when the callback body runs -- 72 (16 + 32 + 24) plus one byte into the
  instrumented callback's own 8-byte frame -- so it confirms that nothing
  is missing below the callback and that `z_add_timeout`'s frame is not
  live there, and it says nothing about when those 40 bytes were spent.
  (The first recording of this item said they were spent after the
  callback returned, and the preflight refuted it against the pinned
  source: the arithmetic was right and the mechanism was not.)
  So this mark is explained, to the byte, by frames the `.su` method can
  see, and the anomaly calls no other row into question. It does not
  establish the method for rows with no QEMU run behind them -- every FRDM
  row, every `isr_<driver>` row -- which is the state the harness's README
  already describes. One row gains empirical support beside it: with the
  forced run at 144 and the excluded at 112, `z_arm_pendsv`'s own use of
  this stack is 144 − 112 − 32 = **0**, which is what the `pendsv` row
  asserts as a literal and `reserves.sh` cannot recompute.
  What was wrong was one enumeration of the k_timer branch, in the note of
  the `timer_dispatch` path file; both boards' notes now name the re-arm
  and say it is the deeper of the two sub-branches, both still below the
  time-slice branch the row's 144 sums. `reserves.sh` is unaffected: the
  row's bytes do not move, and it recomputes them.)
- [x] **`.ARM.exidx` placement** (added in Task 2). Our objects carry one
  `CantUnwind` entry per function; the link must place `.ARM.exidx` through
  Zephyr's linker script, with no orphan-section warning in the link log.
  (Step 9 refuses a link log with an orphan-section warning; the published
  `link.log` and `zephyr.map` show none and the `.ARM.exidx` output
  section holding our objects' entries.)
- A correction to the record of Task 10's commit `68e8488`. Its message
  says three earlier suites (`cross.sh:227`, `channel.sh:79`,
  `platform-facts.sh:121,140`) used GNU grep's `\|` alternation "which BSD
  grep reads literally and which let two absence checks pass on silence".
  That was an inference from the POSIX BRE rule (`\|` is undefined there),
  made on Debian, whose `/usr/bin/grep` is GNU grep; no vacuous pass was
  observed on any host. The macOS implementer measured the Mac's `/usr/bin/grep`
  (BSD grep 2.6.0-FreeBSD, GNU compatible): it honours `\|` and `\( \)`,
  the old patterns matched inputs that contain the strings with the same
  counts as the new `-e`/`-E` forms, and the three suites give the same
  results before and after. The change stands as a portability
  correction and nothing more; the earlier Mac greens on those checks were
  worth what they looked like.

**Admission:** the `mps2/an521` build, plus the controls that do not need a
second firmware build. Estimated at 9 minutes on Debian. The FRDM-MCXN947 build,
the `Pwm` sample, and the controls that need their own firmware are carried to
the final verification if they do not fit. (Measured on Debian at Task 10:
125 s, 37 checks, with the Zephyr environment -- the sample, the FRDM
build, the own-provider build, the thirteen controls each with its own
build, and the QEMU boot all fit; nothing is carried but the sampler's
attestation below. The sampler item added two controls and two checks and
the suite is 40 checks; the figure at that tip is in its own report.
Without the environment the suite skips every check, named.)

## Task 11: The verification build, the trace and the checks

**Files:**

- Create `tools/app/templates/{recorder.c,cycles.c,stimulus.c.erb,nest_timer.c.erb}`
  (as built: the recorder and the cycle wrapper are plain C, copied; the
  stimulus and the nesting source are rendered).
- Create `tools/app/lib/core_app/{trace_schema.tsv,trace,verify}.rb`.
- Add `spinel-core-app verify`.
- Create `tests/app/verify.sh`, `tests/app/fixtures/stimulus/`,
  `tests/app/fixtures/trace/` (one byte fixture per kind), and
  `tests/app/mutate.rb`.

**Interfaces:**

- **The recorder** follows 0014 §10 (a): PRIMASK saved, set and restored,
  compiler barriers, and one ring per context. Its header is generated from
  `trace_schema.tsv`.
- **The nesting source** is `nest_timer`, a verification-only lower-priority
  hardware timer interrupt with busy work. It has its own inventory row and
  reserve, so the system clock interrupt can nest inside it. The recorder logs
  its entry and exit, so nesting is observed, not assumed.
- `CoreApp::Verify.run(trace, app, board_host, channels_host, stimulus) -> Result`
  (as built: `Verify.run(records, app, externs, stimulus, figures:, frames:,
  complete:, replay:)`, the host package loaded by the caller as the host
  runner needs it; `Result#failures` names each record and rule,
  `Result#report` the figures).

- [x] **Decoder fixtures.** Every record kind decodes from its byte fixture. An
  unknown kind, a short record, and a record exceeding a limit are each
  refused.
  (`tests/app/fixtures/trace/<KIND>.bin` with its `.txt`, 20 kinds, decoded
  and encoded back; four `refuse-*.bin` streams, a body the fields do not
  consume among them. The schema is `lib/core_app/trace_schema.tsv`; the C
  header `recorder.h` is generated from it at step 5 and the decoder reads
  it.)
- [x] **The acceptance sample in QEMU** passes the four checks and the replay.
  (`spinel-core-app verify` with `tests/app/fixtures/stimulus/sample.tsv`
  -- 50 ms horizon, 20 ms drain, the ADC and button emulators driven, three
  inbound commands of which the third is oversize, `nest_timer 700 150`:
  712 records, 62 invocations replayed byte for byte; the releases are the
  periods' -- sample 49, report 9, command_poll 4, every one run; 9
  telemetry messages enqueued, handed to the UART and found on the wire in
  order; 2 commands consumed, the third dropped as oversize; 9 cross loads
  each returning the latest store; the end marker quiescent and drained;
  12 s for the build, the run and the checks. What the run settled: the
  recorder performs each cross-context access itself inside its PRIMASK
  section, so the access and its record are one -- the kernel's
  `--record-cross` lowering calls `spc_record_load`/`spc_record_store` in
  place of the atomic access, and is told the hooks' measured frame; the
  target numbers an inbound frame by its order on its channel, since the
  transport cannot know the script's item numbering, and the check maps
  the two; under QEMU's default `-icount shift=7` (128 ns per instruction,
  a fifth of the 25 MHz core's rate) the recorded build starves the
  lowest-priority transport thread and the rings overflow, so `verify` runs
  at shift 5 (32 ns, about the core's rate) and the figures say so; a
  console capture must be raw -- a `tr -d '\r'` on it deletes every 0x0D
  payload byte.)
- [x] **Mutations.** Every mutation of 0014 §10, applied by `mutate.rb`, fails
  with its own diagnostic.
  (Seventeen, over the checked-in trace of the sample's run
  (`tests/app/fixtures/trace/sample-run`): the twelve bullets of §10 --
  the two load mutations on different records, the truncation seen as a
  missing end marker -- plus a release selected and never started, an
  interior record removed with the numbering kept (the gap rule's own),
  and a channel-full drop at an occupancy below depth on its own; each
  refused by `verify --trace-text` with the check's own rule as the first
  failure. They run without QEMU. The preflight added the last three and
  the rule they exercise: a release classed run must have started.)
- [x] **Painted stacks.** The scheduler thread, transport thread and interrupt
  stacks are painted. With `nest_timer` forcing nesting and the failure and
  recorder paths exercised, each high-water mark must stay within its static
  value.
  (The end line prints each mark -- `SPC_STACK name= used= size=` -- from
  Zephyr's stack-space query for the threads and a scan for the paint on
  the interrupt stack; `verify` compares them with `build.json`'s static
  values. The sample, nesting forced (71 expiries, the system clock's
  records inside the handler's START and END): scheduler 1212 of 1672,
  transport 556 of 1520, interrupt 1060 of the chain's 2004. The
  `divides` run, the failure path exercised: scheduler 216 of 720,
  transport 360 of 808, interrupt 152 of 764. Falsification evidence,
  never the value.)
- [ ] **Target fixtures:** (NOT WRITTEN, and not to be: they would replay
  the target against CRuby, an oracle that now runs only on the owner's
  instruction. They are listed under the Handoff's "does not establish",
  with the host tests that cover the same behaviour.)
  - channels in the verification build: wraparound, full and empty, and an
    inbound channel driven past full, with each drop checked against
    occupancy;
  - scheduling: a self-overrun, a cross-entry delay, several missed releases,
    and a long timer interrupt with late expiries doing nothing;
  - lifecycle: an expected-failure run and a horizon-straddling run
    (the expected-failure run is `tests/app/fixtures/build/divides`: an
    i64 overflow at release 5, `expect_failure step 5 2`, FAIL, the four
    remaining releases cancelled, the run passing; a control declaring the
    failure at release 4 is refused);
  - **safe state:** a failure in one context puts that context's output device
    into its safe state, observed through the adapter's recorded calls, while
    an entry in another context keeps producing. A glue variant without the
    safe-state call must fail this fixture.
- [x] **Instruction counts for the deferred D3** (added 2026-09-22). For each
  entry of the acceptance sample, the verification run records instructions
  per invocation and how many of them execute inside `__aeabi_ldivmod`, as
  fields of the run's report, not as a check. QEMU's `icount` makes the counts
  deterministic; the method (a QEMU trace or a cycle-counter delta around the
  invocation and around the helper) is recorded with the figures.
  (Method: `k_cycle_get_64()` around each invocation, and around each
  `__aeabi_ldivmod` call through the linker's `--wrap` (`cycles.c`, an
  assembly wrapper since the helper returns in r0-r3), printed as
  `SPC_CYCLES` lines after the end marker; under `-icount shift=5` an
  instruction is 32 ns of virtual time, so instructions = cycles × 10⁹ /
  (25 000 000 × 32); the wrapper's own instructions are inside the ldivmod
  figure, and the recorder's are inside every figure -- these are the
  verification build's counts, not production's. The acceptance sample
  (Debian, 2026-09-23): sample 1,279 instructions per invocation, report
  4,461, command_poll 1,155, no 64-bit division in any of them. The
  `divides` fixture, one i64 division per release: 200 per invocation,
  4 `__aeabi_ldivmod` calls in 4 invocations costing 405 instructions --
  about 101 per division, the wrapper included -- half the invocation. A
  production build refuses an entry that calls the helper at step 7, since
  its stack is not attested; that refusal, and the figure, are what D3
  decides on.)

**Admission:** one QEMU run of the acceptance sample, plus the mutations and
decoder fixtures, estimated at 9 minutes. The other target fixtures are carried
to the final verification. (Measured on Debian, after the preflight:
`tests/app/verify.sh` 35 checks with the Zephyr environment -- the decoder
fixtures, the seventeen mutations, the sample's run and the `divides` run;
24 checks and 11 skipped, named, without it (the sampler item added one
check to the run section: 36 and 12); the wall times are in the
Task 11 report. The target fixtures other than the expected-failure run
are carried as the plan says.)

**Added after the preflight and the runs (Task 11):**

- The verification build's glue units: `recorder.c` (the rings, the
  section, the hooks), `cycles.c`, the generated `stimulus.c` (the script's
  items as a table, a thread at priority 2, context 2 of the recorder; its
  inbound frames enter the transport through the same byte path as the
  UART's), `nest_timer.c` (CMSDK timer 0 of mps2/an521 programmed directly,
  IRQ 3 at priority 3, an inventory source `nest_timer` whose chain cost is
  `isr_entry_exit` plus its measured frame, admitted past the irqconfig set
  of the screen because it is the declared source), and `xwrap.c` for the
  application's own externs. The transport is rendered for every
  verification build, channels or not, because it drains the rings. The
  stimulus thread's stack is a literal outside the inequalities, unlike the
  Adc sampler's; it runs no entry and no provider.
- The two stack inequalities of a verification build carry the recorder's
  frames on every path, the ldivmod wrapper's on the entries' paths, and the
  nesting handler's on its own level; each measured and summed over its
  call tree.
- Glue and providers alike are compiled with `-DSPC_VERIFY`, which is in
  the flag list and so in every digest: verification evidence binds to the
  verification configuration.

## Task 12: Production primitives under preemption

**Files:**

- Create `tests/app/stress/`: an application and a harness built exactly as
  production, without the recorder or masks.
- Create `tests/app/stress.sh`.

**Interfaces:**

- **The stress interrupt** reads the preempted PC from its exception frame. It
  counts hits between each channel's labels (Task 8), read from the linked
  image's symbol table, per channel and per operation.
- **Content checks:** every message carries a sequence number and a checksum,
  and every shared word carries its low half and the complement of its high
  half.
- **Outcomes.** A run with no hit inside either span is *inconclusive*, never a
  pass.
- **The negative control** uses a mutated ring that publishes the head before
  the copy. Its trigger is targeted: the mutated ring itself pends the stress
  interrupt (through `NVIC->STIR`) immediately after the early publication. The
  vulnerable window is therefore always hit, and the run must fail.

- [x] **Run in QEMU** with an interrupt producer and a thread consumer, and then
  the reverse. Require zero content failures and at least one hit in each span,
  in each direction.
  (Done, 2026-09-23, `tests/app/stress.sh`, both directions in one run: the
  interrupt entry `produce` puts while the transport thread drains, and the
  transport thread puts UART input while the interrupt entry `consume` gets.
  Debian, icount shift 5, 500000 samples every 37 us: telemetry get copy
  4707, get publication 105, commands put copy 113, put publication 6;
  150260 frames off the wire, no checksum mismatch, no sequence that failed
  to rise; the consumer received and checked its messages; no failure.
  What "each span" can mean was settled by measurement, not assumed: the
  sampling source can only preempt the THREAD side of each direction, since
  the interrupt side runs inside the system clock's handler above the
  source's priority, so the spans required are the transport's four; the
  interrupt side's spans read 0 by construction. Three findings on the way.
  A sampler called from an interrupt entry sees only tick boundaries --
  20000 samples, every one the idle loop -- so the build gained a sampling
  source of its own, `--stress` (CMSDK timer 1, a period that is not a
  multiple of the tick, budgeted in the inventory like the nesting source).
  At the board's default icount shift 7 the interrupt entries use the CPU
  and the transport thread never runs (no frame in 15 s), so the run is at
  shift 5. And an application whose glue alone called `k_timer_start` did
  not link: our objects were link items after Zephyr's archives, so a kernel
  member only they needed was never pulled. They are now sources of the
  `app` library, which Zephyr links under `--whole-archive` ahead of
  `libkernel.a`; step 10 reads their `libapp.a(x.o)` names. The acceptance
  sample had linked only because its drivers happened to pull the member.
  A sample taken over another handler (PendSV, the UART's) is not
  classified: `ICSR.RETTOBASE` says whether the preempted context was a
  thread -- 3173 of the 500000 were not. The preflight found that the first
  test, the stacked xPSR on PSP, could never fire: a frame on PSP is only
  pushed from thread mode.)
- [x] **Artifact checks.** Apply Task 5's IR and object checks to the stress
  build's ring and cross accesses.
- [x] **The negative control** fails in every run.
  (Done, with a correction to the control as specified. The artifact checks:
  a `--stress` build publishes each entry's optimised IR, and it carries
  atomics exactly on the cross state -- `produce`'s two stores and `check`'s
  two loads of `shared`, none in `consume` -- and each ring publication in
  the linked image is one store-release inside its label span. The object
  check of the cross accesses themselves is not repeated: an aligned i32
  access is a single instruction on thumbv8m, which the IR already fixes.
  The control, `--mutate-ring-early-publish commands`, publishes the head
  before the copy and holds that window open. As the plan wrote it -- the
  window entered on EVERY put -- it did not fail: measured, 200 of 200
  windows entered and no content failure, because the ring becomes a
  two-deep delay line whose output is complete, in order and well-formed,
  only late, which no sequence or checksum can see. Held on every OTHER put,
  late messages mix with on-time ones and the sequence goes backwards: 4441
  failures in the run. It is also refused statically: moving the store
  empties the publication span, and `labels.rb` rejects the image. The
  plan's NVIC->STIR trigger was not needed; the held window is certain.)

**Admission:** one direction plus the negative control, estimated at 8 minutes.
The other direction and longer runs are carried to the final verification.

## Task 13: Acceptance evidence, documentation and handoff

**Files:**

- Create `tests/app/run.sh`, which enumerates every `tests/app` suite. With
  `REQUIRE_ALL=1`, a skip fails.
- Create `docs/core/applications.md`.
- Update [roadmap](../roadmap.md), `building.md` and `provenance.md`, only to
  what was delivered.

- [x] **Runner bijection.** Suites and files agree in both directions. A removed
  suite fails the runner.
  (`tests/app/run.sh`, twelve suites, with `doom-admission.sh` named as
  excluded: it needs two kernels, and it is an oracle run only on the
  owner's instruction. Measured: with `stress.sh` moved
  aside the runner stops before running anything, naming both lists; with
  the tree as it is the lists agree. The full run is the final
  verification's.)
- [x] **Coverage table.** Fill in the evidence column of the "Coverage" table
  below, for each row: the test file, and whether it ran or was carried.
  `REQUIRE_ALL=1` only proves that suites ran, not that obligations were met, so
  this table is the completion checklist.
- [x] **User guide.** It covers the declarations, what can and cannot be
  written, the commands, the host run, the build and verification. Every
  example in it is built by a test, and anything that is not is labelled.
  ([CORE applications on Zephyr](../core/applications.md). Its one code
  example is the acceptance sample verbatim, which `build.sh` builds and
  `verify.sh` runs; every refusal it names points at the fixture that
  shows it.)
- [x] **Local checks.** Links, whitespace, and no new Python file:
  `git ls-files '*.py'` equals its list at `7a7f453`.
  (All three hold at the handoff tip: `git diff --check` clean, the relative
  links of the changed docs resolve, and the `.py` list is unchanged.)
- [x] **Handoff.** A reviewable candidate: the branch, the tip, the tree, the
  commits per task, the coverage table, and the carry-over list with measured
  or estimated costs. The branch is not merged by this plan.
  (Below, under "Handoff". The tip and its tree are the commit that carries
  this paragraph, and are given with the report of it.)

## Coverage

Each 0014 Validation item, with its task and test. Task 13 fills in the
evidence column.

| 0014 item | task | test | evidence |
|---|---|---|---|
| undeclared extern | 3 | `contract.sh` | `contract.sh` ran, 66/66 (Debian, 60a67f1) |
| `writes` on an `in` buffer | 3 | `contract.sh` (`writes-on-in`) | `contract.sh` ran, 66/66 (Debian, 60a67f1) |
| provider screen: alloc, block, CORE symbol, irq-config | 7, 10 | `board.sh`, `build.sh` | `board.sh` ran, 82/82 (Debian, 60a67f1); `build.sh` ran, 40/40 (Debian, 60a67f1); at 6fe4b7d 39/40, the one failure its own map awk, fixed and not rerun |
| evidence for another target or configuration | 4 | `effects.sh` | `effects.sh` ran, 20/20 (Debian, 60a67f1) |
| non-`isr_ok` extern in interrupt context | 3, 6 | `contract.sh`, `host.sh` | `contract.sh` ran, 66/66 (Debian, 60a67f1); `host.sh` ran, 56/56 (Debian, 60a67f1) |
| state written from two contexts | 6 | `host.sh` | `host.sh` ran, 56/56 (Debian, 60a67f1) |
| cross state passed to an extern | 3 | `contract.sh` | `contract.sh` ran, 66/66 (Debian, 60a67f1) |
| device used from two contexts, including via two modules | 6, 7 | `host.sh`, `board.sh` | `board.sh` ran, 82/82 (Debian, 60a67f1); `host.sh` ran, 56/56 (Debian, 60a67f1) |
| channel end in two contexts | 6 | `host.sh` | `host.sh` ran, 56/56 (Debian, 60a67f1) |
| loop without a derived bound, thread and interrupt | 3 | `contract.sh` | `contract.sh` ran, 66/66 (Debian, 60a67f1) |
| 64-bit cross element on Cortex-M33 | 5 | `lowering.sh` | `lowering.sh` ran, 45/45 (Debian, 60a67f1) |
| member the board does not provide | 7 | `board.sh` | `board.sh` ran, 82/82 (Debian, 60a67f1) |
| driver missing from the effect table | 7 | `board.sh` | `board.sh` ran, 82/82 (Debian, 60a67f1) |
| interrupt source missing from the inventory | 10 | `build.sh` | `build.sh` ran, 40/40 (Debian, 60a67f1); at 6fe4b7d 39/40, the one failure its own map awk, fixed and not rerun |
| `send` with `n = 0` and `n > size` | 5, 8 | `lowering.sh`, `channel.sh` | `channel.sh` ran, 24/24 (Debian, 60a67f1); `lowering.sh` ran, 45/45 (Debian, 60a67f1) |
| `recv` buffer smaller than `size` | 6 | `host.sh` (`channel-buffer`) | `host.sh` ran, 56/56 (Debian, 60a67f1) |
| write past a buffer's end, nothing written outside | 5 | `lowering.sh` (guard canaries) | `lowering.sh` ran, 45/45 (Debian, 60a67f1) |
| undersized thread and interrupt stacks | 10 | `build.sh` | `build.sh` ran, 40/40 (Debian, 60a67f1); at 6fe4b7d 39/40, the one failure its own map awk, fixed and not rerun |
| FPU enabled | 10 | `build.sh` | `build.sh` ran, 40/40 (Debian, 60a67f1); at 6fe4b7d 39/40, the one failure its own map awk, fixed and not rerun |
| call-count fixtures | 4 | `effects.sh` | `effects.sh` ran, 20/20 (Debian, 60a67f1) |
| channel behaviour in the verification build | 11 | `verify.sh` / final | `verify.sh` ran, 36/36 (Debian, 6fe4b7d); the longer runs carried |
| production primitives with coverage | 12 | `stress.sh` / final | `stress.sh` ran, 12/12 (Debian, 6fe4b7d); the longer runs carried |
| scheduling, including a long timer interrupt | 6, 11 | `host.sh`, `verify.sh` / final | `host.sh` ran, 56/56 (Debian, 60a67f1); `verify.sh` ran, 36/36 (Debian, 6fe4b7d); the longer runs carried |
| lifecycle: expected failure, horizon-straddling | 6, 11 | `host.sh`, `verify.sh` / final | `host.sh` ran, 56/56 (Debian, 60a67f1); `verify.sh` ran, 36/36 (Debian, 6fe4b7d); the longer runs carried |
| `mps2/an521` acceptance: build, run, four checks and mutations, stack evidence, painted stacks | 10, 11 | `build.sh`, `verify.sh` | `build.sh` ran, 40/40 (Debian, 60a67f1); at 6fe4b7d 39/40, the one failure its own map awk, fixed and not rerun; `verify.sh` ran, 36/36 (Debian, 6fe4b7d) |
| FRDM-MCXN947 build, and the `Pwm` sample if provided | 10 | final | `build.sh` builds the sample for it (Debian, 60a67f1); no `Pwm` sample, the board has no `pwm-leds`; never run (outside acceptance) |
| DOOM unchanged | 2–5 | `doom-admission.sh`; 42 entries in final | `doom-admission.sh` ran at Tasks 2-5, recorded in their commits (last `8273478`); a Mac run at Task 11 was reported by message and is not recorded here; the 42-entry comparison carried; the longer runs carried |
| safe state while another context continues (0014 §4) | 11 | `verify.sh` / final | `verify.sh` ran, 36/36 (Debian, 6fe4b7d); the longer runs carried |

## Handoff

Branch `feat/core-app-zephyr`, from `main` at `7a7f453` (0014 accepted). Not
merged; delivered only when the final verification passes on both hosts and
the owner accepts it.

| task | commits |
|---|---|
| plan | `fbdf298` `b6b16a9` `70cf701` `ff67de0` `e455c0d` |
| 1, pin and platform facts | `00dace8` `6ab42ed` |
| 2, cross-build and gate | `19a9a87` `e97d866` |
| 3, application contract | `c757505` |
| 4, effects, counts, evidence | `99f5705` |
| 5, lowering | `8273478` `20d0b9c` `8082dd0` |
| 6, declarations, host runner | `8b7d3d7` `ce1b1f1` `246b3c1` `1a22c3e` |
| 7, board package | `2a3fed6` |
| 8, channels and transport | `1140729` |
| 9, reserves and harness | `8e0474d` |
| 10, pipeline, stacks, inventory | `68e8488` `010a7a0` `4697b58` `6bade22` `06d457c` `3d49726`; its list: `392d498` (the sampler's stack), `6e1bf35` `33d3818` (the 16 interrupt-stack bytes) |
| 11, verification build | `9e4d42f` |
| D4, D5 | `60a67f1` |
| 12, primitives under preemption | `6fe4b7d` |
| 13, evidence and handoff | the commit carrying this section |

**Carried to the final verification**, with the costs the table under "Final
verification" gives (measured where it says so): the full `tests/app/run.sh`
with `REQUIRE_ALL=1` on both hosts (30-60 min each, estimated); the 42-entry
DOOM comparison on both (about 1.5 h each, measured on a comparable run);
the core-report, core-stack, core and native-core suites on both; the
Task 12's longer runs on Debian; FRDM and the
carried Task 10 controls on both; and the exposures listed under it -- every
tip since Task 11 on macOS (none has run there), the DOOM mid-course on the
D5 kernel, `cross.sh` and core-report since Task 11, the stress suite's file
chardev (first use on the Mac), and the cross-host INT64_MIN reading of the
pinned analyser.

**Not established by this branch**: running on FRDM-MCXN947 hardware; the
reserve method for rows with no QEMU run behind them (the settling run
settled one row on one board); a trace compared across hosts; the
interrupt side of a ring operation under preemption; and Task 11's target
fixtures, which were never written (the expected-failure run exists and
passes in `verify.sh`), each covered on the host instead:

- channel wraparound, full and empty in the verification build -- the ring
  harness of `tests/app/channel.sh` (wraparound over ten times the depth,
  full refusal with contents unchanged, empty after);
- an inbound channel driven past full, each drop checked against occupancy
  -- the transport harness of `channel.sh`, and its control that a drop
  while the ring has room fails;
- scheduling: self-overrun, cross-entry delay, missed releases -- `host.sh`
  (`sched-overrun`, `sched-cross-delay`, `sched-missed`, `sched-together`);
- a long timer interrupt with late expiries doing nothing, and a
  horizon-straddling run -- `host.sh` (`sched-cut`, the horizon controls);
- safe state while another context continues -- `host.sh`
  (`sched-failure`: the failing context stops and is cancelled, the other
  keeps running); the adapter-level safe-state call is not observed on the
  host.

Whether host coverage is acceptable in their place is the owner's decision.

## Final verification

The owner defines it. These are the carried checks. Each cost is an estimate
until measured.

| check | hosts | estimate |
|---|---|---|
| `REQUIRE_ALL=1 sh tests/app/run.sh` | both | 30–60 min each |
| the 42-entry DOOM object comparison against the `7a7f453` baseline kernel | both | about 1.5 h each (5,851 s measured on Debian for a comparable run, 2026-09-21) |
| `tests/core-report/run.sh`, `tests/core-stack/run.sh`, `tests/core/run.sh`, `tests/native-core/*.sh` | both | under 30 min each |
| Task 12 in both directions, with longer runs | Debian | about 30 min |
| the Task 9 falsification harness, if carried | Debian | about 10 min |
| FRDM-MCXN947 builds, the `Pwm` sample and the carried controls of Task 10 | both | about 20 min |

Running on FRDM-MCXN947 hardware is the owner's, and is not part of acceptance.

**Carried because the per-tip admission was dropped** (the macOS coordinator relaying
the owner, 2026-09-23: one pass of implementation and one verification at the
end; the Mac runs nothing per tip). Each line says what failure it would
catch, so the table is a list of exposures and not a wish:

| carried check | what it would catch |
|---|---|
| every tip since Task 11 on macOS | a Mac-only failure: a bash 3.2 shape, a BSD tool difference, a Mach-O symbol rule. None is suspected in what landed, and none would be seen before this run. |
| the DOOM mid-course on the D5 kernel tip | a kernel change that moves a plain object. D5 adds one node kind on the application lane only, so the host lanes should be untouched, and no run recorded in the repository has confirmed it since Task 5's (`8273478`). |
| `tests/app/cross.sh` and `tests/core-report/run.sh` on the tips after Task 11 | a change in the host objects or the report writer that the app suites do not read. |
| a trace compared across hosts | nothing: a trace is compared WITHIN a host and never across (see the limitation above). The line is here so the absence is deliberate. |
| `tests/core-boundary/arithmetic.sh`: 166 of 170 on Debian, and the cause is a CROSS-HOST SEMANTIC DIFFERENCE IN THE PINNED ANALYSER | The four are `i64min-const`, `i64min-literal`, `i64min-under` and the case-coverage check (63 of 66 executed). The pinned reader truncates the `INT64_MIN` literal on Debian x86-64 and does not on macOS arm64, AT THE SAME PIN. Debian (the Debian implementer, 2026-09-23): `tools/contract/build/spinel-typedump <file> ast` on `D = -9223372036854775808` gives `S bigval -9223372036854775808` with `I value -2147483648` -- INT32_MIN. macOS arm64 (the macOS coordinator, same day): the same command on the branch's reader (vendor 6d69d010, the current pin, built 2026-09-22) gives `bigval` and `value` both `-9223372036854775808`, and a reader built 2026-09-12 from the tree BEFORE the pin move (vendor cad0ad14) gives the same. So the pin move is not the discriminator; the host is, and the shape is width-dependent behaviour in the literal path (negating INT64_MIN through a narrower type gives exactly INT32_MIN). Every other large literal is exact on Debian (`3000000000`, plus and minus `INT64_MAX`). The four failures then follow from the kernel's bigval-versus-value rule (`Eligibility.cpp:323-337`), which is correct and stays. WHAT IS CARRIED is therefore not four failing checks but this: the same source is admitted on one host and refused on the other, in a dependency we ship on. Settling it needs the old pin and the new pin side by side ON DEBIAN, which is the verification `344129d` says it owes, not 0014's. The suite is not on `main`, and `tools/contract` has not changed since 2026-09-12. |
| the suites on macOS, read as a test of that rule | the macOS implementer's point, 2026-09-23: "nothing compares a live trace with the checked-in one" is falsifiable on exactly one host. Debian's runs and the fixture share an interleaving, so a byte comparison that crept back in would pass here and fail only there. If a trace check fails on the Mac at the final verification, that sentence is the first hypothesis. |

**A documented limitation, from Task 11's cross-host measurements.** A trace
is reproducible within a host -- two runs on one host are identical line for
line, epoch and clock readings included -- and is NOT reproducible across
hosts: the record count, the kind multiset, the invocation count, the painted
marks and the D3 figures all agree, while the interleaving differs (at Task
11's tip: six positions of 712 records, the first at record 78, a transport
drain on the other side of a timer-driven invocation). The two SDK host tools
are different builds of QEMU 10.0.2 (Debian's prints
`10.0.2 (v10.0.2-20-g5828172dcf-dirty)`, the Mac's plain `10.0.2`); which
input causes the difference is not established. No check, fixture or claim
depends on cross-host identity: a suite builds and runs on the host it is on
and checks that run's own trace, and the mutations run over the checked-in
fixture, which is a within-file comparison.

## Completion boundary

- Tasks 1–5 are kernel and toolchain work, not an application capability.
- Task 10 without Tasks 11 and 12 is firmware that nothing has compared with
  CRuby, or stressed.
- 0014 counts as delivered only after the final verification passes on both
  hosts and the owner accepts it.
