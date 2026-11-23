# 0045: results

This record is kept beside [decision 0045](0045-buffer-classes.md). The
predictions were committed before the implementation started. The results are
added below them once the checks have run. A prediction that turns out wrong
stays as written, and the result says so.

## Stage 1: main

### Observed before the predictions (2026-11-15)

These observations were made on the Mac (macOS arm64). The worktree is on
`feat/0045-buffer-classes`, built from `6a02e529`: the pinned compiler
(`vendor/spinel` at `4e0a59bd9`), the contract reader and the native tools,
all with the official LLVM 23.1.1. The native build took 558 s.

- A version 2 kernel contract with `scratch 256`, whose entry makes
  `a = Core::Buffer.i32(2)`, gives rc 1 with five refusals. One of them is
  `unresolved-constant: Core::Buffer: Core is not a module of this source`
  at 2:6, and another is `unresolved-call: no scalar effect contract for
  i32` at 2:6. Its `Array.new(2, 0)` twin is admitted (`wrote an.o`).
- The AST face (`spinel-typedump ... ast`) gives every node only
  `node_line` and `node_col`, with no end position.
  `a = Array.new(       n, 2)` (padded to the width of
  `Core::Buffer.i32(`) puts the call at column 6 and `n` at column 23, which
  is where `n` stands in `a = Core::Buffer.i32(n, 2)`.
- Reading the code:
  - Under `run-host`, `tools/app/lib/core_app/host_runner.rb` prepends
    `Array.new`, and in an application file it calls `Scratch#make`
    (decision 0045, section 2, corrected).
  - The scratch route's refusals are in `Core/Eligibility.cpp`, and the
    lowering's failure details are in `Frontend/Scalar/MlirGen.cpp`
    (`arrayNew`).
  - The words `int_array`, `float_array` and `poly_array` reach a refusal
    from `Frontend/Scalar/Importer.cpp`, in the parameter and result checks.
    Only `tests/fs-helper-buffers` expects them (`elem` and `ret`).
  - `tests/app/fixtures/channel/bytes.rb` runs only in an oracle section
    (`tests/ORACLES.tsv`, `tests/app/channel.sh` bytes), so it is migrated
    and is not run here.

### Predictions (2026-11-15, before any implementation)

1. **Where the change lands.** Nothing changes in `vendor/`, the typedump,
   the contract reader's faces, the freestanding reader
   (`Freestanding/Emit.cpp`) or the loop-bound reports. The loop finding's
   header `Array.new N` keeps its text, because its digest is made from it.
   - A new `Core/BufferSpelling.{h,cpp}` scans the source text, skipping
     comments and string literals. It rewrites each `Core::Buffer.<name>(`,
     `::Core::Buffer.<name>(` and `Core::Table.<name>(` to `Array.new(`,
     padded with spaces, and records each one. It also records every
     `Array.new(` the source spells, with the text of its arguments.
     A `Doom::Core::Buffer` is not matched.
   - `Contract/Model.h`: the record is kept on `ContractModule` (line,
     column, class, element and arguments), set by `core::loadContract`.
   - `Core/Input.cpp`: the reader's copy is written whenever the rewrite or
     the 0042 prelude changes the text. The rewrite comes first and keeps
     every line, so the prelude's line arithmetic is unchanged.
   - `Core/Eligibility.cpp`, on the scratch route (checked scalar with a
     version 2 contract), adds three refusals:
     - `array-spelling` for an `Array.new` that the rewrite did not produce,
       suggesting `Core::Buffer.<width>(<the same arguments>)`. A
       `Core::Buffer` call that was not rewritten (no parentheses straight
       after the name) is refused with the same code.
     - `array-element` for a name other than the body's width.
     - `array-table` for `Core::Table`.

     The existing refusals say `Core::Buffer` in place of `Array.new` or
     "array".
   - `MlirGen.cpp`: the failure details say `Core::Buffer`.
   - `Importer.cpp`: the parameter and result refusals say "an Integer
     buffer", "a Float buffer" and "a buffer of more than one element type".
   - `tools/app/lib/spinel/core.rb` defines `Core::Buffer` and `Core::Table`.
     `host_runner.rb`'s prepend moves from `Array.new` to `Core::Buffer`.
   - `docs/imports.tsv` row 93 names `BufferSpelling.cpp`, so
     `tools/dist/manifest.json` is pinned again in its own commit.
2. **`tests/scratch`.**
   - Every accepted program is migrated: the kernel fixtures to
     `Core::Buffer.i64` (the host kernel's 64-bit body) and the
     applications to `Core::Buffer.i32`, except `int64`, which uses `.i64`.
     Each gives the same values, reports and positions as before.
   - Every row of `kernel-reject.tsv` and `app-reject.tsv` keeps its code
     and position, because the columns are kept, except `nofill.rb`. That
     file stays `Array.new(2)` and becomes `array-spelling` at 2:6.
   - Part 2 (thumbv8m) needs a 32-bit twin of `work.rb`, because a
     `.i64` spelling is refused at 32 bits. That refusal becomes a check of
     its own: `array-element`, naming `i64` and `i32`.
   - New kernel rejects:
     - `arraynew.rb` (`array-spelling` at 2:6, its words suggesting
       `a = Core::Buffer.i64(2, 5)`);
     - `element.rb` (`.i32` in the 64-bit body) and `float.rb` (`.f64`),
       both `array-element` at 2:6;
     - `table.rb` (`array-table` at 2:6);
     - `bare.rb` (`Core::Buffer.i64 2` without parentheses,
       `array-spelling`).
   - One new application reject, `reject/arraynew.rb`, is `array-spelling`,
     its words suggesting `Core::Buffer.i32(n, 2)`.
   - Under `run-host`, `capfull` and `samename` still fail with `CAPACITY`
     at release 1, `narrow` with `ARITHMETIC`, and `array`, `wide` and
     `int64` give the same payloads.
3. **`tests/fs-helper-buffers`.** Only the `elem` and `ret` rows change
   words: `'k' parameter 0 'out' is a buffer of more than one element type`
   and `'back' returns an Integer buffer`. The Mac result stays 42 passed,
   0 failed, 1 skipped.
4. **The other routes.** `tests/freestanding` (E077, E079, E084) passes
   unchanged; no freestanding refusal names an array. DOOM, `tests/core-*`,
   `tests/app` and `tests/fiber` are unchanged, because none of their
   sources spells `Core::Buffer`, `Core::Table` or an admitted `Array.new`.
5. **Documents.**
   - `docs/core/applications.md` describes `Core::Buffer` (lines 162-189)
     and the new codes in its refusal table.
   - 0041, `0041-results.md` and 0043 each get one line under their status
     pointing to 0045. 0043's record is on main, although its users are on
     the MPC branch. 0040 and 0043's results are not on main, so they get
     their line in stage 2.
6. **Acceptance.** The suites that `tools/test/affected.rb --base
   origin/main` selects are run once at the end, on the Mac, without
   `doom-loop-reports` and without any CRuby oracle. The `tests/core` 21/12
   failure on the Mac (the x86_64 ELF link) is expected as before. The
   lanes the Mac cannot run are named in the results.

### Results (the Mac, 2026-11-15)

The branch was checked at `54ab20fd` on macOS arm64, with the official LLVM
23.1.1. The native tools were rebuilt after the last C++ change, which took
279 s.

Every suite that `ruby tools/test/affected.rb --base origin/main` selects
was run once, in sequence, each from a fresh temporary `DIR`.
`doom-loop-reports` was left out, and every oracle section stayed closed. The
44 commands took 2464 s. The 33 suites with rc 0 were:

- `tests/app`: `board` 102, `contract` 68, `core-channel`, `cross` 48,
  `effects` 23, `host` 58, `reserves` 43 and `udp` 46;
- `tests/contract/rewrites.sh` 12, `core-bitwise` 48/0/2 and `core-blocks`
  45/0/1;
- `core-boundary`, 12 lanes; `core-eligibility` 52; `intrinsics` 56;
  `core-report` 785/0/1; `core-stack` 28;
- `dist/export.sh` 1;
- `doom-core`: `borrowed-calls` 51, `control-flow` 55 and `source-pack` 104;
- `fiber/core.sh` 81/0/0 and `fs-helper-buffers` 42/0/1;
- `imports` 10; the four `lowering` suites 3, 9, 12 and 6;
- `native-core`: `arith` 152 (1 pending), `driver`, `ledger` and `run`;
- `oracle/check.sh`, `scratch` 72/0/0, `source-stamp` 12,
  `subset/reasons` 42 and `intrinsics-board` 15/0/1.

The suites that did not pass:

- `tests/core/run.sh`: 21 passed, 12 failed. This is the known Mac failure
  (the x86_64 ELF link), as predicted.
- `tests/freestanding/run.sh`: e084 stopped at the start of its host part.
  The new worktree had no runtime bitcode (`tools/llvm/build_rt_bc.sh`, 3 s)
  and no `libSpinelGCRoots.so` (`tools/llvm/passes`, cmake and ninja, 4 s).
  With both built, `sh tests/freestanding/run.sh` passed on the rerun, in
  194 s: "every lane passed", including e084 104/0/2, e077 129/0/1 and
  e079 53/0. e040-frdm needs `FRDM_HOST`. This is an environment step and
  does not come from the change.
- `tests/app/build.sh`: 110 passed, 3 failed (1109 s). The failures are the
  `int64-unlisted` and `int64-row-removed` word checks. macOS's `TMPDIR`
  ends in `/`, so the suite's `W` holds `T//app-build...`, while the
  refusal prints the path with one slash. So `grep "^$U/app.rb:1:"` finds
  nothing, although the refusal itself is right. A build of the same copy
  under `mktemp -d "$TMPDIR/app-build.XXXXXX"` prints the right refusal,
  with a single slash. This is a host defect of the suite, and it is not
  fixed here.
- `tests/core-eligibility/upstream-fields.sh`: 14 passed, 1 failed. The
  check edits a face with `sed '/re/a text'`, which BSD sed refuses
  (`command a expects \ followed by text`). It is a host defect, and it is
  not fixed here.
- `tests/dist/run.sh`: 98 passed, 6 failed, all in P5's archive. BSD tar has
  no `--sort=name` (`STOP: tar: 0 files, want 15`). It is a host defect,
  and it is not fixed here.
- The board lane did not run: `rt1186.sh` skipped it (no IWAD on this Mac),
  so `profile.sh` and `rt1186-play.sh`, which read its image, could not run
  either.

Against the predictions:

1. **Missed: one more place.** `tools/fiber/spinel-fiber-core` refused
   `Array.new` in a `fiber_def` body by its own Prism check, so the migrated
   `reject/fiberbody.rb` was not refused with `spinel-fiber` until that check
   learned `Core::Buffer` and `Core::Table`. The rest landed where
   predicted. The loop finding's header keeps `Array.new N`.
2. **Held, with one addition.** Every migrated row of `tests/scratch` kept
   its code and position, `nofill.rb` became `array-spelling` at 2:6, and the
   host results are unchanged. The thumbv8m part uses `work32.rb`, and
   `work.rb` there is `array-element` naming `i64` and `i32`.

   Found while writing a new check: run-host compared the application's file
   by `File.expand_path` against Ruby's resolved backtrace path. So an
   application reached through a symbolic link (macOS's `TMPDIR`) ran with
   plain Arrays: no `CAPACITY`, and no element width. The coordinator ruled to fix it
   in this branch (`54ab20fd`, `File.realpath` on both sides). Its check, run
   through a symbolic link to `capfull`'s directory, failed on the unfixed
   runner (scratch 71/1/0, got `1:0:0`) and passes with the fix (72/0/0).
3. **Held.** `fs-helper-buffers` 42/0/1, and only `elem` and `ret` changed
   words.
4. **Held,** after the environment step above. No freestanding refusal
   changed, and no other suite failed for a reason the change gave it.
5. **Held.**
6. **Held.** The lanes the Mac did not run are named above.

### Review findings (the reviewer, at `bc0c876c`) and their fixes

1. **Medium: a default fill shifted the columns after it.** The rewrite
   appends `, 0`, so a second call on the same line
   (`a = Core::Buffer.i64(1); b = Core::Buffer.i64(1)`) was not matched to its
   record (`array-spelling` at 2:34). Any refusal after it on that line also
   printed a column 3 off.
   - Fixed in `4e5c8e36`: the rewrite records each insertion, and the
     contract reader moves the entry file's nodes after it back
     (`ContractInputs::columnInserts`).
   - `tests/scratch` builds `kernel/sameline.rb` (`static_proof`, 24 bytes)
     and refuses `kernel/reject/after.rb`'s `push` after a default fill at
     2:27, its written column.
2. **Medium: `spinel-fiber-core` crashed on Prism 0.19.** It called
   `ConstantPathNode#name`, which Debian's Ruby 3.3.8 (Prism 0.19) lacks.
   - Fixed in `e1745101`: `path_name` reads `#name` or `#child.name`, and
     the check looks at a call only inside a fiber body.
   - `tests/fiber/core/pathcall` has constant-path receivers both in a body
     and out of one. On the Mac, under a shim that gives
     `ConstantPathNode` Prism 0.19's shape, the old tool raised
     `NoMethodError` on it and on `reject/fiberbody.rb`, and the new one
     rewrites `pathcall` and refuses `fiberbody` by name.
     `tests/fiber/core.sh` gave 82/0/0 (208 s).
3. **Medium: the hand-written scan read `=begin` inside a heredoc as a
   comment,** and then skipped real calls. Fixed in `9ea13e0b`:
   - `Core/BufferSpelling.cpp` now finds the calls, their parentheses and
     their arguments by parsing with the vendored Prism (1.9.0,
     `vendor/spinel/build/libprism.a`, as the contract reader links it), so
     no Ruby is lexed by hand.
   - `tests/scratch` builds `kernel/quoted.rb`, which has buffer-call text in
     a heredoc after `=begin`, in a `%q` and in a string.
   - **Contract point, from the same finding.** `module Core; Buffer = 17;
     end` was accepted. In a source the reader rewrote, defining
     `Core::Buffer` or `Core::Table` (a module, class, constant, singleton
     class or method) is now `array-reserved`.
     `kernel/reject/reserved.rb` is refused at 2:2. Probes of `module
     Core::Buffer`, `class Table` inside `module Core`, `def Core.Buffer`,
     `Core::Table = 3`, `def self.Buffer` inside `module Core` and `class <<
     Core::Buffer` were each refused once. `module Core; X = 1; end` was
     accepted. Decision 0045 section 3 says so.
   - **The kernel's source stamp now covers Prism.** It records the vendor
     `Makefile` (a blob id, against the pin's at check), which names the
     Prism version that `make deps` fetches, and one digest of
     `vendor/spinel/vendor/prism/{src,include}`
     (`tools/test/source-stamp.rb`). `docs/building.md` says that the native
     build needs `make -C vendor/spinel deps` and the vendor objects first.
   - **Known gap, not widened here.** The reader's stamp covers the vendor's
     `src/`, `Makefile` and `common.mk`, but not the Prism sources it links.
     A Prism fetched again under the same `Makefile` would pass the reader's
     check.

   Checks on the Mac after the fix: `sh tests/scratch/run.sh` 76/0/0 (70
   s), `sh tests/source-stamp/run.sh` 12/0, and
   `sh tests/fs-helper-buffers/run.sh` 42/0/1.

Re-review (the reviewer, at `37848911`): M1 to M3 are closed. It raised two new
points:

4. **Medium: the reserved names could be bypassed through their module.**
   `Core = 17` at the top level, with a `Core::Buffer` call in the source,
   was admitted.
   - Fixed: rebinding `Core` itself is now `array-reserved`: `Core = ...`,
     `::Core = ...`, `Core ||= ...`, `Core, x = ...`, and `class Core < X`.
     An ordinary `module Core ... end` stays allowed.
   - `kernel/reject/rebind.rb` is refused at 1:0. Probes of the other four
     forms were each refused once. `module Core; X = 1; end` gave rc 0.
     `class Core; end` is refused only by the existing
     `binding-environment`.
5. **Low: a parse error after a default fill printed the copy's columns.**
   The reader's copy gave 1:51 and 1:53 where the source has 1:48 and 1:50.
   - Fixed: the failure path in `Core/Input.cpp` maps columns back through
     `sourceColumns`, the mapping the contract reader uses
     (`contract::sourceColumn`).
   - `tests/scratch` checks that `kernel/reject/parse.rb`'s errors are at
     1:48 and 1:50, and that none is at 1:51 or 1:53.

   `sh tests/scratch/run.sh` on the Mac after the fix: 78/0/0 (70 s).

Scoped re-review (the reviewer, at `40b5c970`): point 4 is closed. Point 5 held
for the reported case, a BOM, the prelude and two insertions, but one
boundary remained. `a = Core::Buffer.i64(1 +)` was refused at 2:26 with
"unexpected comma", while the source has no comma and the plain reader says
2:27, an unexpected `)`. There were two causes:

- the rewrite appended `, 0` to a count that was already broken;
- `sourceColumns` passed the diagnostic's column, which counts from 1,
  where the record's columns count from 0.

The fix takes the reviewer's narrow course. A source that Prism cannot parse is
not rewritten at all, so the reader's own diagnostics stand. `sourceColumns`
also converts the column from 1-based to 0-based before mapping and back
after. `kernel/reject/badcount.rb` is refused at 2:27 with no "comma". On
the Mac, `sh tests/scratch/run.sh` gave 79/0/0 (67 s), after a 155 s native
rebuild.

### Results after the review fixes (the Mac, `05fa6b00`)

The suites that `ruby tools/test/affected.rb --base origin/main` selects
were run once more, in sequence, with each command in a fresh `DIR`. The run
left out `doom-loop-reports` and kept the oracle sections closed. It had 45
commands, one more than the first run (`tests/freestanding/stamp-controls.sh`,
7/0), and took 2606 s.

- **rc 0 (39 commands).** Every suite that passed in the first run passed
  again, with the same counts, except for the suites the fixes extended:
  `scratch` 79/0/0, `fiber/core` 82/0/0 and `source-stamp` 12/0.
  `freestanding/run.sh` gave "every lane passed" (221 s), now that the
  worktree has the runtime bitcode and the pass plugin.
- **Not passing (6 commands), the same as the first run.**
  - The Mac host defects outside 0045 named above failed with the same items:
    `tests/core` 21/12, `app/build` 110/3 (`TMPDIR`), `upstream-fields`
    14/1 (BSD sed) and `dist/run` 98/6 (BSD tar).
  - The board lane was skipped (no IWAD), so `profile.sh` and
    `rt1186-play.sh` could not run.
