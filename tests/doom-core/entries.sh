#!/bin/sh
#
# tests/doom-core/entries.sh — decision 0008's three entries and their field maps.
#
# tools/doom/core-entries.rb generates doom_core_input, doom_core_step and
# doom_core_render, their contracts and examples/doom/core/entries/fields.tsv
# from the port's signatures and the state and access manifests. This checks:
#
#   * the committed files are what the generator writes (a hand edit, or a
#     manifest change nobody regenerated, is refused);
#   * tests/doom-core/entry-fields.rb holds on the committed files against the
#     layout tools/doom/state-schema.rb generates -- a second generator;
#   * each refusal, by its own message: a field of another element, a manifest
#     that gives the entry only `in` for a buffer the contract writes, an access
#     row nobody takes, a not-taken row for a field the entry takes, a
#     derived: row whose field the entry does not take or the port never
#     reads, a zero table out of Jobs#reset's order, and a body that leaves a
#     scalar parameter ungiven.
#
# It needs no reader and no WAD. The entries' behaviour is
# tests/doom-core/step-diff.rb's and render-diff.rb's.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RUBY="${RUBY:-ruby}"
CORE="$ROOT/examples/doom/core"
GENE="$ROOT/tools/doom/core-entries.rb"
CHECK="$ROOT/tests/doom-core/entry-fields.rb"
JOBS="$ROOT/examples/doom/lib/doom/jobs.rb"

die() { echo "entries: $*" >&2; exit 1; }
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
TAB=$(printf "\\t")
W=$(mktemp -d "${TMPDIR:-/tmp}/doom-core-entries.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
want() { if grep -qE "$3" "$2"; then echo "  pass $1"; pass=$((pass + 1));
         else echo "  FAIL $1"; sed 's/^/        /' "$2" | head -5; fail=$((fail + 1)); fi; }

echo "the committed entries are the generator's"
"$RUBY" "$GENE" --out "$W/regen" > "$W/regen.err" 2>&1 && echo 0 > "$W/regen.rc" || echo $? > "$W/regen.rc"
ok "the generator runs" "$(cat "$W/regen.rc")" 0
want "  and says what it made" "$W/regen.err" '^core-entries: doom_core_step: 219 buffer\(s\), 1 scalar\(s\)$'
same=0
for f in src/doomentry.rb entries/doom_core_input.contract entries/doom_core_step.contract \
         entries/doom_core_render.contract entries/fields.tsv; do
  cmp -s "$W/regen/$f" "$CORE/$f" && same=$((same + 1)) || echo "    differs: $f"
done
ok "all five files are what it writes" "$same" 5

echo "the field map, against the generated layout"
cat "$CORE/catalog.tsv" "$CORE/prepared.tsv" > "$W/full-catalog.tsv"
"$RUBY" "$ROOT/tools/doom/state-schema.rb" --schema "$CORE/state.tsv" --access "$CORE/access.tsv" \
  --catalog "$W/full-catalog.tsv" --output "$W/gen" > "$W/gen.err" 2>&1 || die "the layout does not generate: $(tail -1 "$W/gen.err")"
check() { # entries-dir access out
  "$RUBY" "$CHECK" "$1" "$W/gen" "$CORE/state.tsv" "$2" "$JOBS" > "$3" 2>&1 && echo 0 > "$3.rc" || echo $? > "$3.rc"
}
check "$CORE/entries" "$CORE/access.tsv" "$W/fields.out"
ok "the committed map holds" "$(cat "$W/fields.out.rc")" 0
want "  the step entry's 221 buffers cover its 329 access rows" "$W/fields.out" \
  '^entry-fields: doom_core_step: 221 buffer\(s\), 329 field\(s\) taken, 329 access row\(s\) covered: ok$'
# 211, 342 and 398 since decision 0021: the status bar and the HUD draw from the
# render entry's one WAD buffer, renderer_wad_data, which they alias.
want "  the render entry's 211 cover its 398" "$W/fields.out" \
  '^entry-fields: doom_core_render: 211 buffer\(s\), 342 field\(s\) taken, 398 access row\(s\) covered: ok$'
want "  and the zero table is Jobs#reset's" "$W/fields.out" '^entry-fields: render-zero.tsv: 31 cell\(s\), Jobs#reset.s zeroes: ok$'

want "  and every unit is packed or excluded with a reason" "$W/fields.out" '^entry-fields: units.tsv: 23 unit\(s\) packed, 4 excluded with a reason: ok$'

# Each control alters one input in a copy and must be refused for its own reason.
# An edit is a sed expression, or `APPEND text`, which adds one line: BSD sed's
# `a` wants a backslash and a newline where GNU sed takes the text on the same
# line, and macOS measured the difference (entries.sh failed there 1 s in).
mutant() { # label file sed-expression|APPEND-line pattern [access]
  rm -rf "$W/mc"; mkdir -p "$W/mc"; cp -r "$CORE/entries" "$W/mc/entries"; cp "$CORE/sources.tsv" "$W/mc/"; ln -s "$CORE/src" "$W/mc/src"
  case $3 in
    "APPEND "*) { cat "$CORE/entries/$2"; printf '%s\n' "${3#APPEND }"; } > "$W/mc/entries/$2" ;;
    *) sed "$3" "$CORE/entries/$2" > "$W/mc/entries/$2" ;;
  esac
  cmp -s "$CORE/entries/$2" "$W/mc/entries/$2" && { echo "  FAIL $1 (the edit changed nothing)"; fail=$((fail + 1)); return; }
  check "$W/mc/entries" "${5:-$CORE/access.tsv}" "$W/m.out"
  ok "$1" "$(cat "$W/m.out.rc")|$(grep -cE "$4" "$W/m.out")" "1|1"
}
mutant "a field of another element is refused" fields.tsv \
  "s/^doom_core_render${TAB}scr${TAB}renderer_screen${TAB}u8${TAB}/doom_core_render${TAB}scr${TAB}game_mobj_x${TAB}u8${TAB}/" \
  'doom_core_render scr: game_mobj_x is i32, the map says u8'
mutant "a contract mode the map does not say is refused" doom_core_step.contract \
  "s/^param mobj_x buffer i32 inout /param mobj_x buffer i32 in /" \
  'doom_core_step mobj_x: the contract says i32 in, the map i32 inout'
mutant "an access row no parameter takes is refused" not-taken.tsv \
  "/^doom_core_step${TAB}game_sprnames${TAB}/d" "doom_core_step: access.tsv's game_sprnames is taken by no parameter and no slot"
mutant "a not-taken row for a field the entry takes is refused" not-taken.tsv \
  "APPEND doom_core_step${TAB}game_mobj_x${TAB}constants${TAB}a wrong row" 'doom_core_step: not-taken.tsv lists game_mobj_x, which the entry takes'
mutant "a same: row whose target the entry does not take is refused" not-taken.tsv \
  "s/same:renderer_colormap/same:job_executor_colormap_x/" 'job_executor_colormap is the same as job_executor_colormap_x, which the entry does not take'
mutant "a derived: row whose field the entry does not take is refused" not-taken.tsv \
  "s/^\(doom_core_render${TAB}renderer_ds_srcres${TAB}\)derived:renderer_curpicnum${TAB}/\1derived:renderer_curpicnum_x${TAB}/" \
  'doom_core_render: renderer_ds_srcres is derived from renderer_curpicnum_x, which the entry does not take'
# and one whose field the port's source never reads: the units copied, with the
# one read of renderer_curpicnum's cell (rx[R_CURPICNUM]) spelled another way
rm -rf "$W/mr"; mkdir -p "$W/mr"; cp -r "$CORE/entries" "$W/mr/entries"; cp "$CORE/sources.tsv" "$W/mr/"; cp -r "$CORE/src" "$W/mr/src"
sed 's/rx\[R_CURPICNUM\]/rx[R_CURPICNUM + 0]/' "$CORE/src/rview.rb" > "$W/mr/src/rview.rb"
check "$W/mr/entries" "$CORE/access.tsv" "$W/mr.out"
ok "a derived: row whose field the port's source never reads is refused" \
   "$(cmp -s "$CORE/src/rview.rb" "$W/mr/src/rview.rb" && echo same || echo edited)|$(cat "$W/mr.out.rc")|$(grep -c "doom_core_render: renderer_ds_srcres is derived from renderer_curpicnum, which the port's source never reads (rx\[R_CURPICNUM\])" "$W/mr.out")" "edited|1|1"
mutant "a zero table out of Jobs#reset's order is refused" render-zero.tsv \
  "s/^0${TAB}jobs_nwall$/0${TAB}jobs_nspan/; s/^1${TAB}jobs_nspan$/1${TAB}jobs_nwall/" "render-zero.tsv is not Jobs#reset's zeroes: .*order differs"
mutant "a slot table naming a buffer is refused" step-slots.tsv \
  "s/^0${TAB}\([A-Z_]*\)${TAB}.*/0${TAB}\1${TAB}game_mobj_x/" 'doom_core_step gx: game_mobj_x is not a slot of the layout'
sed "s/^doom_core_step${TAB}game_mobj_x${TAB}inout$/doom_core_step${TAB}game_mobj_x${TAB}in/" "$CORE/access.tsv" > "$W/access-in.tsv"
mutant "a buffer the manifest gives only in is refused against the inout map" fields.tsv "s/^#entry/#entry /" \
  'doom_core_step mobj_x: game_mobj_x is in in access.tsv, the map says inout' "$W/access-in.tsv"

mutant "a unit neither packed nor excluded is refused" units.tsv \
  "/^rvgpu.rb${TAB}/d; /^#excluded${TAB}rvgpu.rb${TAB}/d" 'units.tsv is not sources.tsv less its #excluded units: unaccounted rvgpu.rb;'
mutant "and so is one both packed and excluded" units.tsv \
  "APPEND rvgpu.rb${TAB}0" 'units.tsv both packs and excludes rvgpu.rb'

mutant "a slot row whose field the entry has no access row for is refused" input-slots.tsv \
  "APPEND 6${TAB}X_GAMETIC${TAB}game_gametic" 'doom_core_input xi: game_gametic is a slot of its table and access.tsv gives doom_core_input no row for it'
mutant "a slot row whose constant names no source constant is refused" step-slots.tsv \
  "s/^0${TAB}\([A-Z_]*\)${TAB}/0${TAB}G_NOT_A_CONSTANT${TAB}/" 'doom_core_step gx: G_NOT_A_CONSTANT is defined in no unit'
mutant "a slot row whose constant is another position is refused" render-slots.tsv \
  "s/^0${TAB}\([A-Z_]*\)${TAB}/0${TAB}R_CHECKED${TAB}/" 'doom_core_render rx: R_CHECKED is 109 in the source and row 0 of its table'
mutant "a position out of order is refused by name, not by a crash" render-zero.tsv \
  "s/^3${TAB}jobs_nsched$/x${TAB}jobs_nsched/" 'refused render-zero.tsv: row 3 says position "x"'
mutant "an exclusion with an empty reason is refused" units.tsv \
  "s/^#excluded${TAB}rvgpu.rb${TAB}.*/#excluded${TAB}rvgpu.rb${TAB} /" 'units.tsv excludes rvgpu.rb without a reason'

echo "the line flags' render-to-step coupling stays harmless"
# level_line_flags IS WRITTEN BY RENDER AND READ BY STEP: Renderer#store_wall_range
# sets ML_MAPPED (bit 256), and eight step definitions read the flags. That is
# harmless ONLY because nothing tests bit 256 -- the shipped program has no
# automap -- so no step result depends on what render writes there. The
# writers column cannot show this; this check does. If anything else ever names
# ML_MAPPED (an automap, a read of the bit), it fails, and the coupling must be
# looked at again.
grep -rn 'ML_MAPPED' "$ROOT/examples/doom/lib" "$ROOT/examples/doom/bin" > "$W/mapped.txt" || true
ok "ML_MAPPED appears only as its constant and render's one write" \
  "$(wc -l < "$W/mapped.txt" | tr -d ' ')|$(grep -c 'ML_MAPPED = 256$' "$W/mapped.txt")|$(grep -c 'flags\[linedef\] = flags\[linedef\] | ML_MAPPED$' "$W/mapped.txt")" "2|1|1"
grep -rn '& *256\b\|0x100\b' "$ROOT/examples/doom/lib/doom/game.rb" "$ROOT/examples/doom/lib/doom/mapmove.rb" \
  "$ROOT/examples/doom/lib/doom/sight.rb" "$ROOT/examples/doom/lib/doom/specials.rb" "$ROOT/examples/doom/lib/doom/enemy.rb" \
  "$ROOT/examples/doom/lib/doom/inter.rb" "$ROOT/examples/doom/lib/doom/pspr.rb" > "$W/bit256.txt" || true
ok "  and no step file masks bit 256 by number" "$(wc -l < "$W/bit256.txt" | tr -d ' ')" 0

echo "the generator's own refusals"
rm -rf "$W/core"; mkdir -p "$W/core"
cp -r "$CORE/src" "$CORE/entries" "$W/core/"
cp "$CORE/state.tsv" "$CORE/access.tsv" "$W/core/"
# a body whose callee gains a scalar parameter it does not give
sed 's/^def dc_st_take_message(state, gx)$/def dc_st_take_message(state, gx, extra)/' "$CORE/src/stepplay.rb" > "$W/core/src/stepplay.rb"
sed 's/  msg = dc_st_take_message(state, gx)/  msg = CALL dc_st_take_message()/' "$GENE" > "$W/gene-call.rb"
"$RUBY" "$W/gene-call.rb" --core "$W/core" --out "$W/out1" > "$W/call.err" 2>&1 || true
want "a scalar parameter the body does not give is refused" "$W/call.err" \
  "doom_core_step: dc_st_take_message's extra is not a buffer and is not given"
cp "$CORE/src/stepplay.rb" "$W/core/src/stepplay.rb"
grep -v "^doom_core_step${TAB}game_mobj_x${TAB}" "$CORE/access.tsv" > "$W/core/access.tsv"
"$RUBY" "$GENE" --core "$W/core" --out "$W/out2" > "$W/noacc.err" 2>&1 || true
want "a buffer the manifest does not give the entry is refused" "$W/noacc.err" \
  "doom_core_step: mobj_x is game_mobj_x, and access.tsv gives doom_core_step no row for it"

# a body that names a buffer no call binds and `buffers:` does not list
awk 'BEGIN{d=0} /buffers: %w\[cmd\],/ && !d {sub(/%w\[cmd\]/, "%w[]"); d=1} {print}' "$GENE" > "$W/gene-nobuf.rb"
ok "  the control drops one buffers: list" "$(diff "$GENE" "$W/gene-nobuf.rb" | grep -c '^[<>]')" 2
"$RUBY" "$W/gene-nobuf.rb" --core "$CORE" --out "$W/out3" > "$W/nobuf.err" 2>&1 || true
want "a buffer the body names and nothing binds is refused" "$W/nobuf.err" \
  "doom_core_input: the body names cmd, n_cmd, which is not a parameter"

echo "Full refuses a pending rebirth before the step"
"$RUBY" "$ROOT/tests/doom-core/rebirth-guard.rb" > "$W/rebirth.out" 2>&1 && rc=0 || rc=$?
ok "Session#before_step! passes its checks" "$rc|$(tail -1 "$W/rebirth.out")" "0|rebirth-guard: all pass"
mkdir -p "$W/rg/tests/doom-core" "$W/rg/examples/doom/core/full"
cp "$ROOT/tests/doom-core/rebirth-guard.rb" "$W/rg/tests/doom-core/"
sed 's/      PST_REBORN = 2/      PST_REBORN = 3/' "$ROOT/examples/doom/core/full/session.rb" > "$W/rg/examples/doom/core/full/session.rb"
"$RUBY" "$W/rg/tests/doom-core/rebirth-guard.rb" > "$W/rebirth-wrong.out" 2>&1 && rc=0 || rc=$?
ok "  and a guard reading the wrong state value fails them" \
   "$rc|$(diff "$ROOT/examples/doom/core/full/session.rb" "$W/rg/examples/doom/core/full/session.rb" | grep -c '^[<>]')|$(grep -c '^  FAIL PST_REBORN is refused$' "$W/rebirth-wrong.out")" "1|2|1"

echo "the source entries' buffer elements are their fields' (tools/doom/source-elements.rb)"
SE="$ROOT/tools/doom/source-elements.rb"
"$RUBY" "$SE" --check > "$W/se.out" 2>&1 && rc=0 || rc=$?
ok "every bound buffer parameter declares its field's element" \
   "$rc|$(grep -c '^source-elements: [0-9]* bound buffer parameter(s), 0 differ, 0 refused$' "$W/se.out")" "0|1"
# A contract put back to the element its field had before decision 0018.
mkdir -p "$W/se/examples/doom/core" "$W/se/tests/doom-core/fixtures"
cp "$CORE/state.tsv" "$W/se/examples/doom/core/"
cp -r "$ROOT/tests/doom-core/fixtures/source" "$W/se/tests/doom-core/fixtures/"
sed 's/^param atlas buffer u8 in /param atlas buffer i64 in /' "$ROOT/tests/doom-core/fixtures/source/col.contract" \
  > "$W/se/tests/doom-core/fixtures/source/col.contract"
"$RUBY" "$SE" --root "$W/se" --check > "$W/se-wrong.out" 2>&1 && rc=0 || rc=$?
ok "  and a parameter declaring another element is named" \
   "$rc|$(diff "$ROOT/tests/doom-core/fixtures/source/col.contract" "$W/se/tests/doom-core/fixtures/source/col.contract" | grep -c '^[<>]')|$(grep -c '^source-elements: differs col.contract: atlas i64 -> u8 (textures_texdata, job_executor_atlas)$' "$W/se-wrong.out")" "1|2|1"

echo "entries: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ]
