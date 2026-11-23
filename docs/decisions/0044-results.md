# 0044: results

The record [decision 0044](0044-freestanding-helper-buffers.md) keeps beside
it. The predictions were committed before the implementation started, and the
results are added below them when the checks have run. A prediction that turns
out wrong stays as written, and the result says so.

## The one stage: a helper indexes a buffer its caller lent it

### Observed before the predictions (2026-11-14)

On the Mac (macOS arm64), with this branch's tip `ff4cfad7` built in a
worktree: the pinned compiler (`vendor/spinel` at `baddd25a9`), the contract
reader and the native tools, all with the official LLVM 23.1.1. The probes
were compiled with `spinel-fs-emit` for the `wasm32-worker` and
`x86_64-linux-host` profiles (compile only); both profiles gave the same
lines.

- The first implementer's `m1_helper_buf.rb`: rc 1,
  `unsupported: 'fill' parameter 0 'buf' is float_array`.
- The first implementer's `m1b_helper_decl.rb`: rc 1,
  `unsupported: 'process': argument of fill is a boolean; only Integer values are in the subset`.
- `x = out; x[0] = 1` in an entry: rc 1, refused by the subset table before
  any type is read: `` `a[i] = v` writes into a heap object; see `[]`. A
  buffer declared `:out` or `:inout` is the exception. ``
- `out[0] = out` in an entry: rc 1, `'process' parameter 0 'out' is
  poly_array`: inference gives the array two element types.
- Reading the code: the importer's subset check (`fsSubsetCheck`) knows a
  buffer only from the root's declaration, so a helper's `buf[i] = v` would be
  refused by the same heap-write row once the signature is admitted. The
  freestanding range check reads the length from the entry's `:len` local;
  Declaration's stage B already refuses reassigning a buffer or a `:len`
  parameter of an entry, so that local cannot move.

### Predictions (2026-11-14, before any implementation)

1. **Where the change lands.** Nothing in `vendor/`, the contract reader, the
   typedump, the profiles or the freestanding DSL.
   - `include/spinel-mlir/Scalar/Importer.h`: a selected parameter can carry a
     lent buffer (its element, its mode and whether it is checked), next to
     its type. The status lane's `ScalarBorrowedParam` is not reused: that
     table is the eligibility checker's answer, and this route has no checker.
   - `lib/Frontend/Scalar/Importer.cpp`, freestanding only: after the closure
     is selected, each parameter is derived from the calls that reach it (D1).
     An entry's declared buffer is a source. A call whose argument names a
     buffer the caller holds (its own declared buffer, or a buffer lent to
     it) lends it to the callee's parameter at that position. The derivation
     runs to a fixed point, so a buffer lent on by a helper, and a helper that
     calls itself, need nothing more. A parameter whose inferred type is an
     array becomes a lent buffer when the derivation found it one.
   - `lib/Frontend/Scalar/MlirGen.cpp`: a lent parameter is two arguments,
     the pointer and then the length, at the Integer width of the body (L1).
     A call passes the pointer and the length it holds: an entry's declared
     `:len` parameter, or the length its own caller lent it. The length is
     never a Ruby name in the helper, so a helper cannot move it.
   - Every access through a lent parameter checks `0 <= i < len` against that
     length and traps with code 4, as an entry does (B1). Under U1 a lent
     parameter skips the check only when every buffer that reaches it comes
     from an entry declared `bounds: :unchecked`; one checked source makes it
     checked. This is decided per parameter, which for a helper reached from
     two entries is what the record states per helper: the helper checks.
   - `needInt` and `needNumeric` name what the value is: a buffer, a boolean,
     or nil.
2. **The first implementer's two probes, admitted** (decision 0044's checks, first item).
   - `m1_helper_buf.rb` (a plain `fill(buf, i)`): rc 0.
   - `m1b_helper_decl.rb` (`fill` declared `[[:f32_buf, :inout], :len, :i32]`,
     called as `fill(out, frames, i)`): rc 0. `fill` is also an entry, so it
     keeps its C prototype and its wrapper, and the call from `process` goes to
     the body directly, past the wrapper. Because the wrapper is skipped, the
     call checks at run time that the length argument it passes for `buf`,
     `frames`, is at most the length the caller holds for `out`, and traps
     with code 4 if it is not. Without that check a caller could pass
     `(out, frames + 9)` and the callee's own range check would compare
     against the larger length.
3. **The entry's boundary does not move.** For every entry in the checks, the
   `--emit-header` prototype is byte for byte what it is before the change: a
   read-only buffer is still `const T *`, a writable one `T *`, the length
   `int64_t` or `int32_t` as now. A plain helper has no C prototype, so the
   record's "the emitted C of a read-only lent parameter says `const`" has no
   C to check. What is checked instead is the property behind it: a helper
   that stores into a parameter lent from an `:in` buffer does not compile
   (prediction 6).
4. **Values, by hand.** A kernel file (`tests/fs-helper-buffers/k.rb`) with
   these entries, each given buffers by a driver that fills them and prints
   them after the call:
   - `fill_all(out, n)`, `[[:f32_buf, :inout], :len]`: a plain helper
     `put(b, i, v)` stores `v` into `b[i]` for `i` in `0...n`, with
     `v = i * 0.5`. With `n = 4`: `out` is `0 0.5 1 1.5`, the return is 4.
   - `lend_on(out, n)`, `[[:i32_buf, :inout], :len]`: `outer(b, n)` lends `b`
     on to `inner(b, i)`, which stores `i * i`. With `n = 5`: `0 1 4 9 16`.
   - `two(a, b, na, nb)`, `[[:i32_buf, :inout], [:i32_buf, :inout], :len,
     :len]`: one helper `bump(buf, i)` reached with `a` and with `b`, each
     with its own length. With `na = 3`, `nb = 2`, `a = 10 20 30`,
     `b = 7 8`: `bump` adds 1 to `a[0..2]` and `b[0..1]`, giving `11 21 31`
     and `8 9`; the return is the sum of the read-back values, 80.
   - `past(a, b, na, nb, i, j)` with the same buffers: `bump(a, i)` then
     `bump(b, j)`. `(i, j) = (2, 1)` returns normally; `(3, 0)` traps with
     code 4 at `a`'s length 3, and `(0, 2)` traps with code 4 at `b`'s length
     2 after `a[0]` was bumped. The hook's two numbers are the index and the
     length: `4 3 3` and `4 2 2`.
   - `sum_in(src, n)`, `[[:i32_buf, :in], :len]`: a helper `get(b, i)` reads
     through a parameter lent from an `:in` buffer and returns the element;
     `src = 3 4 5` gives 12.
   - `each_lent(src, dst, n)`, `[[:i32_buf, :in], [:i32_buf, :out], :len]`:
     a helper `walk(s, d)` walks its lent `s` with `each_with_index` (0041's
     literal block) and stores `v + i` into its lent `d`; `src = 1 1 1` gives
     `dst = 1 2 3`. (A block that stores into the buffer it walks is refused
     by 0041's classifier, the first implementer's m3f; that is not this decision's.)
   - `unchecked_put(out, n, i)`, declared `bounds: :unchecked`: its helper
     has no range check (U1). This is checked in the IR, not by running an
     out-of-range store: the helper's function holds no trap-4 branch, and
     the same helper reached from a checked entry as well holds one.
5. **Targets.** The kernel file compiles for the four freestanding profiles:
   the x86_64 Linux host, wasm32, Cortex-M33 and RV32. On this Mac:
   - x86_64 host: compiled and linked with the C driver only on x86_64 Linux,
     so a named skip here, run on Debian.
   - wasm32 (a 32-bit body): linked with wasm-ld and run under node, with the
     same values and traps as above, the hidden length being an `i32`.
   - Cortex-M33 and RV32: compiled here (object only). Running them on QEMU
     and on the FRDM-MCXN947 board is Debian's (the coordinator or the second implementer).
6. **Refusals, each by name** (decision 0044's checks):
   - A store through a parameter lent from an `:in` buffer: refused at
     compile time, naming the helper, the store and the call that lends the
     `:in` buffer.
   - A parameter reached with two element types (an `:f32` buffer at one
     call, an `:f64` buffer at another): refused, naming both calls.
   - A buffer stored into a local (`x = buf`) and a buffer stored into an
     element (`out[i] = buf`): refused with the corrected message, which says
     "is a buffer". (The record's "a state slot" has no counterpart on this
     route: there is no state slot.)
   - A helper that returns its lent buffer: refused, as today, because the
     helper's return is an Array (`non-integer-return`).
   - A buffer passed where the callee takes a number: for a callee that is
     an entry too, refused by name ("argument 0 of 'f' is the buffer `out`,
     and 'f' declares it `:i32`"). For a plain helper, inference already
     refuses it, because one parameter then has two types (`poly`); that
     message is unchanged.
   - A lent buffer passed to a platform extern, or taken as a view
     (`buf[off, n]`): refused by name as outside 0044, which admits indexing
     and lending on only.
   - The old message: no input in these checks gives "is a boolean" for a
     value that is not a boolean.
7. **Nothing else moves.** The suites the change touches (by
   `tools/test/affected.rb --base`) pass as before on this Mac; the
   freestanding lanes this Mac cannot run are named in the report.
8. **Not run:** CRuby or any other oracle.

### Results (2026-11-14, the Mac)

The implementation is `1fbef8fb` and the checks are `973d6c03`, both on
`feat/0044-fs-helper-buffers`. Everything below ran on the Mac (macOS
arm64) with the official LLVM 23.1.1, against the native build of this
branch held to its source stamp. No CRuby and no oracle was run.

`sh tests/fs-helper-buffers/run.sh`: 35 passed, 0 failed, 1 skipped, 3 s.
The skip is part 1, the x86_64 Linux host build, which does not run on
this Mac.

1. **Where the change landed: as predicted.** The changed files are
   `Importer.h`, `Importer.cpp`, `FreestandingSubset.{h,cpp}` and
   `MlirGen.cpp`. Nothing changed in `vendor/`, the reader, the profiles or
   the DSL. One more site needed the change: the subset check
   (`fsSubsetCheck`) now takes the lent parameters' names, so that `b[i] = v`
   and `each` on a lent buffer are not refused as heap writes. The
   observations above had foreseen this.
2. **The first implementer's two probes: as predicted.** Both give rc 0 for the x86_64
   host, wasm32, Cortex-M33 and RV32 profiles (part 3). The length check of
   a call into an entry callee, which `m1b`'s call to `fill` gets too, is run
   by `via_entry` in `k.rb`.
3. **The prototypes: as predicted.** `sum_in`'s `:in` buffer is
   `const int32_t *`. `setk` keeps its prototype although `via_entry` calls
   it. No helper has a prototype (part 4). The emitted IR shows the L1
   signature: `@sp_put(ptr, i32, i32, double)` on wasm32, a buffer's address
   and length followed by `i` and `v`.
4. **The values: as predicted, on wasm32.** `expect.txt` was compared line by
   line with prediction 4's hand values before it was committed. Three
   things differ from what prediction 4 wrote, and none is a different
   value:
   - The entries `two` and `past` are declared
     `[[:i32_buf, :inout], :len, [:i32_buf, :inout], :len, ...]`, that is
     `two(a, na, b, nb)`. This is because a `:len` counts the buffers
     before it.
   - `checked_put` was added to the rows: index 1 stores 8, giving
     `0 8 0`; index 3 traps `4 3 3`.
   - The hook's numbers for `via_entry 1` are `4 4 3`, the length passed
     and the length held.

   Every row: `fill_all 4 0 0.5 1 1.5`, `lend_on 5 0 1 4 9 16`,
   `two 80 11 21 31 8 9`, `past 2 1 40`, `past 3 0 trap 4 3 3` with `a`
   untouched, `past 0 2 trap 4 2 2` with `a[0]` already 11, `sum_in 12`,
   `each_lent 3 1 2 3`, `via_entry 0 0 5 0 0`, `via_entry 1 trap 4 4 3`.
   The x86_64 run of `drive.c` against the same file is Debian's.
5. **U1: as predicted.** In the wasm32 IR, `sp_uput` has no
   `spinel_trap(i32 4, ...)` call and `sp_mput` has one. `put`, `inner`,
   `bump` and `get` each have at least one (part 5).
6. **Refusals: five as predicted, two not.**
   - As predicted, each by its own words:
     - the store through a buffer lent from `:in` (`in_store`);
     - the two element types, naming both calls (`two_elems`);
     - an `:in` buffer passed to an entry callee that declares `:inout`
       (`in_entry`);
     - a lent buffer passed to a platform extern (`extern`) and taken as a
       view (`view`), both on E083's wasm32 profile;
     - `x = buf` (`local`), which now says "the value assigned to `x` is a
       buffer; ...". No refusal in the set says "is a boolean".
   - The returned buffer is refused as `'back' returns int_array`, as
     predicted.
   - **Not as predicted:**
     - `b[i] = b`, a buffer stored into an element (`elem`), never reaches
       the new message. Inference gives the entry's array two element types
       first: `'k' parameter 0 'out' is poly_array`, the same refusal an
       entry got before the change.
     - A buffer passed where an entry callee takes a number (`num_entry`)
       does not reach the importer's new refusal either. Inference gives
       that parameter two types first: `'g' parameter 2 'x' is poly`.

     The importer still keeps its check for a source that inference would
     type differently. Both rows test the refusal that actually fires.
7. **Nothing else moves: not as predicted.**

   `tools/test/affected.rb --base ff4cfad7` selected 35 commands. One is
   left out: `tests/doom-core/loop-reports.sh`, which takes about 3 h; the
   owner's rule runs it once, at the end of the whole effort. The other 34
   ran one at a time on the Mac at `002214d7`. 31 exited 0 and 3 exited 1.

   - **`tests/freestanding/run.sh`: `failed: e077 e079`. Caused by this
     decision, and not predicted.** Three rows were written to show that a
     buffer could not be passed inward, and decision 0044 admits all three:
     - E077's `b05_pass_buf`, whose helper takes the buffer and does not
       index it;
     - E077's `b05b_callee_index`, whose helper indexes it;
     - E079's `b05_buffer_to_callee`.

     These are three prediction misses. At the coordinator's word, `4a8d5a98` makes
     each a control. Each must build and export its entry (`nm`), and its
     comment names decision 0044. `e079/oracle/tables/reject.tsv` is left as
     it was. It still records `REFUSE` for `b05_buffer_to_callee`, so it
     now disagrees with the lane, and it runs only under `ALLOW_ORACLE`.
     The limits that remain are refused in `tests/fs-helper-buffers`, each
     by its words: a stored buffer (`local`, `elem`), a returned one
     (`ret`), a write through a buffer lent from `:in` (`in_store`,
     `in_entry`), two element types (`two_elems`), and a platform extern
     or a view (`extern`, `view`). E077's `b06_buf_as_value` still refuses
     a buffer used as a value in an entry.

     The rerun at `faa63015` gave `run: every lane passed` in 182 s
     (e077 129 pass and e079 53 pass, each with 0 fail). In that run,
     `e040-frdm` and `bm040-frdm` were NOT RUN, because `FRDM_HOST` was
     unset.
   - **`tests/dist/export.sh`: the export refused a scratch path.** The path
     is on line 30 of the decision record, which came in with `8d3f8e3d`.
     `faa63015` rewords that line, at the coordinator's word, and the rerun of the
     export passed (1 of 1, 43 s).
   - **`tests/core/run.sh`: 21 passed, 12 failed.** This failure is known on
     this Mac and is not this change's: the suite uses the x86_64 Linux
     host profile, and gives `ld: unknown file type in 'k32.o'`. The same
     21/12 was recorded on this Mac before. The coordinator accepted it. The suite
     runs on Debian in the merge check.

   The 31 that passed, with their counts:

   | suite | result |
   |---|---|
   | affected | 67 pass |
   | app/cross | 48 pass |
   | core-bitwise | 47 pass, 2 skipped |
   | core-blocks | 45 pass, 1 skipped |
   | core-boundary | 12 lanes pass |
   | core-eligibility | 52 pass |
   | intrinsics | 56 pass |
   | core-report | 785 pass, 1 skipped |
   | core-stack | 28 pass, 1 skipped |
   | `git diff --check` on docs | rc 0 |
   | borrowed-calls | 51 pass |
   | control-flow | 55 pass |
   | source-pack | 104 pass |
   | fiber core | 81 pass |
   | fs-helper-buffers | 35 pass, 1 skipped |
   | imports | 10 pass |
   | lowering | 29 pass, across its 4 suites |
   | native-core arith | 150 pass, 1 pending |
   | native-core driver | 44 pass |
   | native-core ledger | 28 pass |
   | native-core run | 8 pass |
   | oracle/check | rc 0 |
   | source-stamp | 12 pass |
   | subset map | 13 pass |
   | subset reasons | 42 pass |
   | subset-tables | 12 pass |
   | intrinsics-board | 15 pass, 1 skipped (no board) |

   `rt1186` skipped its board lane.

   The rows of `tools/test/affected.tsv`, `tests.tsv` and
   `docs/imports.tsv` that this branch adds changed three files the export
   rewrites. Their pins were renewed in `002214d7`.
8. **Not run:** CRuby, any oracle (`ALLOW_ORACLE` unset), `BASELINE_KERNEL`.

### Review findings (the reviewer, at `393e2e59`) and their fix

The reviewer reviewed `393e2e59` on Debian and reproduced each finding there.
The coordinator confirmed the intended contract for both. The reviewer found nothing
further. Ten of the reviewer's own length cases passed: recursive forwarding,
zero and out-of-range indexes, an entry callee given a larger, a smaller
or a negative length, and buffers swapped between calls. A store through
`:in -> helper -> helper` was refused, as intended.

1. **HIGH: U1 was lost through an entry callee.** In the example, `checked`
   is a default (checked) entry. It calls `bridge`, an entry declared
   `bounds: :unchecked`, which calls the plain helper `leaf`. `leaf` had no
   range check. On Debian, `spinel_checked(buf, 1, 1)` returned 0 and
   overwrote a canary past the length it held. The cause:
   `heldBuffer` gave an entry's buffer the entry's own `bounds:` setting,
   so `bridge`'s setting replaced the setting of the entry that called it.
   - **Fix (`e5522fd8`).** The selector walks the closure's call edges from
     every entry declared with checked bounds, through entry callees as
     well. A lent parameter skips its check only when no such entry reaches
     its helper.
   - **Control.** `chain` in `k.rb`: index 1 stores 7; index 3 traps
     `4 3 3`, and the canary after the buffer stays 91. In the IR, `leaf`
     has a trap-4 call.
   - **Found by the author during the fix.** An entry declared `bounds:
     :unchecked` kept its own unchecked accesses when a checked entry called
     it; the call checked only the length it passed. The coordinator ruled that such
     an entry is, for that call, a helper of a checked root.
     - `96b22000`: a method body, entry or helper, is unchecked only when no
       entry declared with checked bounds reaches it, itself included. Its
       exported C boundary does not change.
     - Control (`581ff765`): `chain2` calls the unchecked entry `bridge2`,
       which does `b[i] = 6`. Index 1 stores 6; index 3 traps `4 3 3`, and
       the canary stays 91. In the IR, `bridge2` has a trap-4 call, and
       `unchecked_put`, which no checked entry calls, has none.
2. **MEDIUM: modes were collapsed.** The selector reduced the modes that
   reach a parameter to a single one (`in`, then `out`, then `inout`). It
   checked only a read-only buffer against an entry callee, and the
   lowering refused only a store. So three cases compiled, each reading a
   buffer the caller declared `:out`:
   - a helper reading a buffer lent from an `:out` entry;
   - a helper walking one with `each`;
   - an `:out` entry calling an `:in` entry.

   The entry itself refuses the same direct read.
   - **Fix (`e5522fd8`).** A lent parameter keeps every mode that reaches
     it, through any chain, each with the chain that brings it.
     - A store is refused when an `:in` source reaches the parameter, and a
       read (an `each` or `each_with_index` walk too) when an `:out` source
       does.
     - A call into an entry callee is refused when a mode that reaches the
       argument forbids what the callee's declaration does: the callee
       writes unless it is declared `:in`, and reads unless it is declared
       `:out`.
     - Each refusal names the chain.
   - **Controls (`3f5fb3ea`).**
     - `modes` in `k.rb` gives `modes 9 4 4`. Its writing helper is lent
       `:out` and `:inout` buffers, and its reading helper `:in` and
       `:inout` ones.
     - Four new refusals: `out_read` (through a relay; its message names a
       chain of two calls), `out_each`, `out_entry` and `out_entry_direct`.
     - `in_store` and `in_entry` now name the chain too.

These two findings are also prediction misses. Prediction 1 said U1 was
"decided per parameter ... one checked source makes it checked". That was
wrong for a source that is an entry callee. The mode rule of predictions 1
and 6 covered `:in` and not `:out`.

After the fixes, `sh tests/fs-helper-buffers/run.sh` gave 42 passed, 0
failed, 1 skipped on the Mac. The new lines of `expect.txt` were written by
hand before the run, and the wasm32 output equals the file.
`tools/test/affected.rb --base 393e2e59` selected 29 commands, without
loop-reports. They ran one at a time on the Mac at `581ff765`. 28 exited 0.
`tests/core/run.sh` gave the known 21 passed, 12 failed (above). The
results:

| suite | result | wall |
|---|---|---|
| app/cross | 48 pass | 23 s |
| core-bitwise | 47 pass, 2 skipped | 8 s |
| core-blocks | 45 pass, 1 skipped | 4 s |
| core-boundary | 12 lanes pass | 109 s |
| core-eligibility | 52 pass | 3 s |
| intrinsics | 56 pass | 7 s |
| core-report | 785 pass, 1 skipped | 92 s |
| core-stack | 28 pass, 1 skipped | 4 s |
| borrowed-calls | 51 pass | 3 s |
| control-flow | 55 pass | 7 s |
| source-pack | 104 pass | 56 s |
| fiber core | 81 pass | 200 s |
| freestanding | every lane passed (FRDM lanes not run) | 184 s |
| fs-helper-buffers | 42 pass, 1 skipped | 3 s |
| imports | 10 pass | 2 s |
| lowering, 4 suites | 29 pass | 2 s |
| native-core arith | 150 pass, 1 pending | 155 s |
| native-core driver | 44 pass | 26 s |
| native-core ledger | 28 pass | 2 s |
| native-core run | 8 pass | 4 s |
| oracle/check | rc 0 | 12 s |
| source-stamp | 12 pass | 1 s |
| subset reasons | 42 pass | 4 s |
| intrinsics-board | 15 pass, 1 skipped | 17 s |
| rt1186 | board lane skipped | 0 s |

**Re-review (the reviewer, at `d29f12f3`).** Both findings are closed and there
are no new ones. On Debian, `sh tests/fs-helper-buffers/run.sh` gave 44
passed, 0 failed, 0 skipped, including the x86_64 host build with
`drive.c` and the `modes`, `chain` and `chain2` rows. The reviewer also ran
their own probes: the `:out` reads, `each` walks and entry calls are each
refused with the chain, a helper lent both `:in` and `:out` refuses a read,
the ten length cases pass, and the three canary controls pass.

**Lanes this Mac did not run.**
- The x86_64 Linux host build of `k.rb` with `drive.c` (part 1 of
  `tests/fs-helper-buffers/run.sh`), and `tests/core/run.sh`.
- `k.rb` on QEMU Cortex-M33 and RV32: it is compiled for both profiles here,
  and not run. (`tests/freestanding/run.sh` ran its own lanes' Zephyr QEMU
  runs here.)
- The FRDM-MCXN947 board lanes, and `tests/doom-core/loop-reports.sh`.
