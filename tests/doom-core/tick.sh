#!/bin/sh
#
# tests/doom-core/tick.sh — decision 0008 task 6.
#
# THE INVENTORY. 0008 asks for "a call-site inventory proving every original
# tick edge was migrated"; the inventory is a comparison rather than a claim.
# Every definition of the three entries is now in a final ledger state, so the
# ledger tool exits 0 here, and the controls below plant an unported definition,
# a partial row and an unported caller to show it naming each. "Migrated" means
# named and present; tests/doom-core/step-diff.rb and render-diff.rb compare.
# This script exits nonzero only when one of its checks fails. The source-port
# sections beside the original are retired (tests/doom-core/harness/retired.sh).
#
# Tools can be supplied prebuilt: KERNEL (spinel-core-kernel), ADAPTER
# (spinel-core-adapter) and SPINEL_TYPEDUMP (the contract reader) override the
# in-tree builds; LLVM_PREFIX or CLANG names the compiler, WAD the IWAD.
# An IWAD is looked for at WAD and at build/doom-wad/doom1.wad inside the
# checkout, and nowhere else: a lane with no IWAD SKIPs. No path outside the
# checkout is searched, so what these lanes do never depends on what happens
# to be lying around a particular host.
#
# The ORIGINAL edges come from the audit's measured closure. The MIGRATED
# definitions come from tools/doom/core-migrated.tsv, each of which must exist
# in the packed CORE source as the contract reader reads it. A name match is
# not a migration: the port renames, and matching by name alone called two of
# the tick's 238 definitions migrated before that table existed.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
. "$ROOT/tests/doom-core/harness/retired.sh"
LEDGER="${LEDGER:-$ROOT/tools/doom/migration-ledger.rb}"
AUDIT="${AUDIT:-$ROOT/tools/doom/audit-core.rb}"
PACK="${PACK:-$ROOT/tools/doom/pack-core.rb}"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else CC_BIN=""; fi
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
RUBY="${RUBY:-ruby}"

die() { echo "tick: $*" >&2; exit 1; }
[ -f "$LEDGER" ] || die "no ledger tool at $LEDGER"
[ -x "$READER" ] || die "no reader at $READER (build it first)"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
# THE BUILT ARTIFACTS ARE MADE IN ONE PLACE. The compiled entries, libsource.so,
# the session layout and libadapter.so are recipes the case runner needs too, so
# they live in harness/artifacts.sh and this sources them rather than keeping a
# second copy that would drift. Sourcing defines functions and runs nothing.
[ -f "$ROOT/tests/doom-core/harness/artifacts.sh" ] || die "no artifact recipes at $ROOT/tests/doom-core/harness/artifacts.sh"
. "$ROOT/tests/doom-core/harness/artifacts.sh"

TAB=$(printf "\\t")
# WHERE THE TIME GOES. Every section prints when it started and how long the
# section before it took, and the end of the run prints the total and the
# sections by cost. This is measurement only: no check, no pin and no verdict
# depends on it, and the section headings themselves are unchanged.
TICK_T0=$(date +%s)
TICK_SECTION=""
TICK_SECTION_T0=$TICK_T0
TICK_TIMES=""
section() {
  now=$(date +%s)
  if [ -n "$TICK_SECTION" ]; then
    TICK_TIMES="$TICK_TIMES$((now - TICK_SECTION_T0))${TAB}${TICK_SECTION}
"
    echo "tick-time  $(date +%H:%M:%S)  +$((now - TICK_T0))s  $((now - TICK_SECTION_T0))s in: $TICK_SECTION"
  fi
  TICK_SECTION=$1
  TICK_SECTION_T0=$now
  echo "tick-time  $(date +%H:%M:%S)  +$((now - TICK_T0))s  section: $1"
  echo "== $1 =="
}
tick_times() {
  now=$(date +%s)
  if [ -n "$TICK_SECTION" ]; then
    TICK_TIMES="$TICK_TIMES$((now - TICK_SECTION_T0))${TAB}${TICK_SECTION}
"
    echo "tick-time  $(date +%H:%M:%S)  +$((now - TICK_T0))s  $((now - TICK_SECTION_T0))s in: $TICK_SECTION"
  fi
  echo "tick-time  $(date +%H:%M:%S)  total $((now - TICK_T0))s"
  printf '%s' "$TICK_TIMES" | sort -rn | while IFS="$TAB" read -r secs name; do
    echo "tick-section  ${secs}s  $name"
  done
}
W=$(mktemp -d "${TMPDIR:-/tmp}/doom-core-tick.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0; skip=0; skips=""
# A RUN STATES WHAT IT COVERED (as state.sh): every skipped lane is counted and
# named in the summary with what would enable it; REQUIRE_ALL=1 fails on any.
skipped() { # lane, reason, what enables it
  echo "  SKIP $1: $2 ($3)" >&2
  skip=$((skip + 1))
  skips="$skips
tick: skipped $1: $2; enable with $3"
}
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
want() { if grep -qE "$3" "$2"; then echo "  pass $1"; pass=$((pass + 1));
         else echo "  FAIL $1"; sed 's/^/        /' "$2" | head -5; fail=$((fail + 1)); fi; }

section "the tick's own closure, measured"
mkdir -p "$W/audit"
"$RUBY" "$AUDIT" --reader "$READER" --tables "$ROOT/tools/doom" \
  --output "$W/audit" > "$W/audit.err" 2>&1 || true
[ -s "$W/audit/closure.tsv" ] || die "the audit produced no closure"
want "the audit completes" "$W/audit.err" 'audit-core: COMPLETE'

section "the packed CORE source"
"$RUBY" "$PACK" --manifest "$ROOT/examples/doom/core/sources.tsv" \
  --root "$ROOT/examples/doom/core/src" --reader "$READER" \
  --output "$W/packed.rb" --map "$W/map.tsv" > "$W/pack.err" 2>&1 \
  && echo 0 > "$W/pack.rc" || echo $? > "$W/pack.rc"
ok "the CORE units pack" "$(cat "$W/pack.rc")" 0

section "every original tick edge, by name"
"$RUBY" "$LEDGER" --closure "$W/audit/closure.tsv" --entry step \
  --packed "$W/packed.rb" --migrated "$ROOT/tools/doom/core-migrated.tsv" \
  --reader "$READER" --output "$W/ledger.tsv" > "$W/ledger.err" 2>&1 \
  && echo 0 > "$W/ledger.rc" || echo $? > "$W/ledger.rc"
want "the ledger counts what the tick reaches" "$W/ledger.err" \
  'step: 240 definition\(s\) reachable, 181 migrated, 58 absorbed into fields, 0 unreached in a configuration, 0 partial \(0 remaining path\(s\) named\), 0 to go \(0 of them accessors whose field is ready and whose callers are not\)'
want "and says the builtins are not definitions to move" "$W/ledger.err" \
  '29 builtin name\(s\) over 3490 site\(s\) are not definitions to move'
# NOTHING REMAINS, so it exits 0; the controls below make it name what remains.
ok "it exits zero now that nothing remains" "$(cat "$W/ledger.rc")" 0
want "and says which definition only touched eliminated storage" "$W/ledger.err" \
  'step: 1 definition\(s\) whose only effect is eliminated storage \(Random#tic=\)'
# AND IT SAYS WHAT IT DOES NOT PROVE. A row is a name mapping plus an
# existence check, not evidence that the named replacements reproduce the
# original -- which is how `add_thinker` counted as migrated while the
# func/data store existed nowhere in CORE source.
want "and says what 'migrated' does not mean" "$W/ledger.err" \
  'NAMED AND PRESENT in the packed source, not proved equivalent'

# CODE NO SHIPPED CONTENT RUNS is counted apart; tests/doom-core/content-scan.rb
# checks each claim against the IWAD, and the ledger refuses one it cannot read.
want "the ledger counts what no shipped content runs" "$W/ledger.err" \
  'step: 9 moved definition\(s\) name 10 part\(s\) the shipped program does not run \(Game#a_cpos_attack, Game#a_cpos_refire, Game#a_head_attack, Game#a_skull_attack, Game#a_spid_refire, Game#g_ticker, Game#give_by_sprite, Game#t_fire_flicker, Game#t_move_ceiling\)$'
sed "s/absent-in-content:doom1:things=3006/absent-in-content:doom1:things=lostsoul/" "$ROOT/tools/doom/core-migrated.tsv" > "$W/badclaim.tsv"
"$RUBY" "$LEDGER" --closure "$W/audit/closure.tsv" --entry step \
  --packed "$W/packed.rb" --migrated "$W/badclaim.tsv" --reader "$READER" > "$W/badclaim.err" 2>&1 || true
want "  and a claim it cannot read is refused by name" "$W/badclaim.err" \
  'Game#a_skull_attack names absent-in-content:doom1:things=lostsoul, which is not a content or construction claim this reads'

section "what is migrated, and what replaced it"
want "the fixed-point helpers"     "$W/ledger.tsv" "^Game#fixed_mul${TAB}migrated${TAB}fixed_mul${TAB}"
want "the angle normalisation"     "$W/ledger.tsv" "^Game#bam${TAB}migrated${TAB}fixed_bam${TAB}"
# THREE names, not two: the middle one is the func/data store, which the row
# left out until Mac review of 33da4d9 found it living in the test instead.
want "and the thinker list, split in three" "$W/ledger.tsv" \
  "^Game#add_thinker${TAB}migrated${TAB}dc_take_slot,dc_store_thinker,dc_link_slot${TAB}"
want "and both generators, kept apart"  "$W/ledger.tsv" \
  "^Random#p_random${TAB}migrated${TAB}dc_p_random,dc_st_p_random,unreached-path:trace:comparison-log${TAB}"
want "the menu's generator separately"  "$W/ledger.tsv" \
  "^Random#m_random${TAB}migrated${TAB}dc_m_random,dc_st_m_random${TAB}"
# A DEFINITION WITH NO ROW REMAINS, and is named: the control drops try_move's row.
grep -v "^Game#try_move${TAB}" "$ROOT/tools/doom/core-migrated.tsv" > "$W/unported.tsv"
"$RUBY" "$LEDGER" --closure "$W/audit/closure.tsv" --entry step \
  --packed "$W/packed.rb" --migrated "$W/unported.tsv" --reader "$READER" --output "$W/unported-ledger.tsv" \
  > "$W/unported.err" 2>&1 && echo 0 > "$W/unported.rc" || echo $? > "$W/unported.rc"
want "what remains is named"       "$W/unported-ledger.tsv" "^Game#try_move${TAB}todo${TAB}${TAB}"
ok "  and the ledger exits nonzero while it remains" "$(cat "$W/unported.rc")" 1

section "a migration cannot be claimed without the definition"
# A row naming something the packed source does not define is refused. That is
# what stops the table from being a list of intentions.
{ grep -v "^Game#try_move${TAB}" "$ROOT/tools/doom/core-migrated.tsv"
  printf 'Game#try_move%sdc_not_written%sclaimed but never written\n' "$TAB" "$TAB"
} > "$W/claimed.tsv"
"$RUBY" "$LEDGER" --closure "$W/audit/closure.tsv" --entry step \
  --packed "$W/packed.rb" --migrated "$W/claimed.tsv" --reader "$READER" \
  > "$W/claimed.err" 2>&1 || true
want "a replacement that does not exist is named" "$W/claimed.err" \
  'name a replacement the packed source does not define: Game#try_move -> dc_not_written'

# And a row for an original no entry reaches describes nothing. (The table is
# shared: a render row is not dead because the step entry does not reach it.)
{ cat "$ROOT/tools/doom/core-migrated.tsv"
  printf 'Game#no_such_method%sfixed_bam%sdescribes nothing\n' "$TAB" "$TAB"
} > "$W/dead.tsv"
"$RUBY" "$LEDGER" --closure "$W/audit/closure.tsv" --entry step \
  --packed "$W/packed.rb" --migrated "$W/dead.tsv" --reader "$READER" \
  > "$W/dead.err" 2>&1 || true
want "a row for an unreached original is named" "$W/dead.err" \
  'name an original no entry reaches: Game#no_such_method'
ok "and the step ledger, over the same shared table with its render rows, names no dead row" \
  "$(grep -c 'no entry reaches' "$W/ledger.err")" 0

section "the other two entries have their own inventories"
for e in input render; do
  "$RUBY" "$LEDGER" --closure "$W/audit/closure.tsv" --entry "$e" \
    --packed "$W/packed.rb" --migrated "$ROOT/tools/doom/core-migrated.tsv" \
    --reader "$READER" --output "$W/ledger-$e.tsv" > "$W/ledger-$e.err" 2>&1 || true
  want "$e has a measured inventory" "$W/ledger-$e.err" \
    "$e: [0-9]+ definition\\(s\\) reachable, [0-9]+ migrated, [0-9]+ absorbed into fields, [0-9]+ unreached in a configuration, [0-9]+ partial \\([0-9]+ remaining path\\(s\\) named\\), [0-9]+ to go \\([0-9]+ of them accessors"
done
# EVERY RENDER DEFINITION IS IN A FINAL STATE since the render spine was ported:
# migrated, absorbed, or unreached in a configuration (the trace recorders, and
# since decision 0008's 2026-10-21 clarification the job list and its executor). No row is partial any more, so the partial and absorbing
# controls below plant a partial or an unported caller themselves.
want "render: every definition migrated, absorbed or unreached" "$W/ledger-render.err" \
  'render: 150 definition\(s\) reachable, 62 migrated, 67 absorbed into fields, 21 unreached in a configuration, 0 partial \(0 remaining path\(s\) named\), 0 to go \(0 of them accessors whose field is ready and whose callers are not\)'
# emit_column, whose wall branch was the one path reached through another
# definition, is unreached in configuration jobs
want "  and no path reached through another definition" "$W/ledger-render.err" \
  'render: 0 moved definition\(s\) name 0 path\(s\) reached through another definition$'
want "the walls' seg loop" "$W/ledger-render.tsv" "^Renderer#render_seg_loop${TAB}migrated${TAB}dc_render_seg_loop,dc_sl_wall_column,dc_sl_light_index,unreached-path:trace:trace-column-calls${TAB}"
want "and set_texture_column, as the selector" "$W/ledger-render.tsv" "^Renderer#set_texture_column${TAB}migrated${TAB}dc_sl_wall_column,dc_sl_src_texture_column,unreached-path:jobs:source-base${TAB}"
want "draw_column: the walls' paths, the spine's dispatch, the direct path, and the job path unreached" "$W/ledger-render.tsv" \
  "^Renderer#draw_column${TAB}migrated${TAB}dc_sl_wall_column,dc_sl_draw_column,dc_rv_column,dc_rv_draw_fuzz_column,dc_rv_draw_column,dc_draw_column,unreached-path:jobs:emit-column${TAB}"
want "the texture atlas bases, absorbed" "$W/ledger-render.tsv" "^Textures#atlas_base${TAB}absorbed${TAB}field:textures_tex_atlas_base${TAB}"
want "and the texture data" "$W/ledger-render.tsv" "^Textures#texdata${TAB}absorbed${TAB}field:textures_texdata${TAB}"
# A PARTIAL note must name its remaining paths, and a remaining path must be in
# a PARTIAL row: each is refused by name. The first control plants a PARTIAL note.
sed "s/^\(JobExecutor#run${TAB}[^${TAB}]*${TAB}\)/\1PARTIAL: planted. /" "$ROOT/tools/doom/core-migrated.tsv" > "$W/partial-unnamed.tsv"
"$RUBY" "$LEDGER" --closure "$W/audit/closure.tsv" --entry render \
  --packed "$W/packed.rb" --migrated "$W/partial-unnamed.tsv" --reader "$READER" > "$W/partial-unnamed.err" 2>&1 || true
want "a PARTIAL row that names no remaining path is refused" "$W/partial-unnamed.err" \
  'JobExecutor#run is PARTIAL and names no remaining path'
sed "s/^Renderer#fixed_div${TAB}fixed_div${TAB}/Renderer#fixed_div${TAB}fixed_div,remaining:nothing${TAB}/" "$ROOT/tools/doom/core-migrated.tsv" > "$W/partial-unsaid.tsv"
"$RUBY" "$LEDGER" --closure "$W/audit/closure.tsv" --entry render \
  --packed "$W/packed.rb" --migrated "$W/partial-unsaid.tsv" --reader "$READER" > "$W/partial-unsaid.err" 2>&1 || true
want "and a remaining path in a row that does not say PARTIAL is refused" "$W/partial-unsaid.err" \
  'Renderer#fixed_div names remaining:nothing and its note does not begin with PARTIAL'
sed "s/^\(Renderer#draw_column${TAB}\)\([^${TAB}]*\)${TAB}/\1\2,remaining:fuzz-dispatch,remaining:Renderer#draw_masked_column${TAB}PARTIAL: planted. /" "$ROOT/tools/doom/core-migrated.tsv" > "$W/partial-other.tsv"
"$RUBY" "$LEDGER" --closure "$W/audit/closure.tsv" --entry render \
  --packed "$W/packed.rb" --migrated "$W/partial-other.tsv" --reader "$READER" > "$W/partial-other.err" 2>&1 || true
want "and a remaining path that names another definition is refused: its row counts it" "$W/partial-other.err" \
  'Renderer#draw_column names remaining:Renderer#draw_masked_column, a definition'
want "an accessor absorbed into two fields" "$W/ledger-render.tsv" \
  "^Sprites#frame_rotate${TAB}absorbed${TAB}field:sprites_rotate,field:sprites_framebase${TAB}"
# AN ACCESSOR IS ABSORBING WHILE A CALLER IS UNPORTED: the control drops the row
# of project_sprite, one of frame_lump's two callers.
grep -v "^Renderer#project_sprite${TAB}" "$ROOT/tools/doom/core-migrated.tsv" > "$W/absorbing.tsv"
"$RUBY" "$LEDGER" --closure "$W/audit/closure.tsv" --entry render \
  --packed "$W/packed.rb" --migrated "$W/absorbing.tsv" --reader "$READER" --output "$W/absorbing-ledger.tsv" \
  > "$W/absorbing.err" 2>&1 || true
want "and one whose field is ready while an unported caller still calls it" "$W/absorbing-ledger.tsv" \
  "^Sprites#frame_lump${TAB}absorbing${TAB}field:sprites_lump,field:sprites_framebase${TAB}"
want "a definition no configuration reaches, counted apart" "$W/ledger-render.tsv" \
  "^Renderer#trace_wall${TAB}unreached${TAB}unreached-in-config:trace${TAB}"
# An absorbed accessor names fields the schema has: a misspelled one is refused
# by name, like a replacement the packed source does not define.
sed "s/field:level_node_bbox/field:level_node_boxes/" "$ROOT/tools/doom/core-migrated.tsv" > "$W/absorbed-bad.tsv"
"$RUBY" "$LEDGER" --closure "$W/audit/closure.tsv" --entry render \
  --packed "$W/packed.rb" --migrated "$W/absorbed-bad.tsv" --reader "$READER" > "$W/absorbed-bad.err" 2>&1 || true
want "a row absorbing a field the schema does not have is named" "$W/absorbed-bad.err" \
  'Level#node_bbox -> field:level_node_boxes \(not a field of '

want "the status bar's drawing, with one call per ammo row" "$W/ledger-render.tsv" "^StatusBar#draw${TAB}migrated${TAB}dc_draw_statusbar,dc_ammo_pair${TAB}"
want "and the HUD's message line" "$W/ledger-render.tsv" "^Hud#draw${TAB}migrated${TAB}dc_draw_hud${TAB}"
want "the plane spans: make_spans" "$W/ledger-render.tsv" "^Renderer#make_spans${TAB}migrated${TAB}dc_make_spans${TAB}"
want "and map_plane, with the span push written out" "$W/ledger-render.tsv" "^Renderer#map_plane${TAB}migrated${TAB}dc_plane_span,unreached-path:trace:span-record${TAB}"
want "draw_planes, the whole walk and the per-plane body it calls" "$W/ledger-render.tsv" "^Renderer#draw_planes${TAB}migrated${TAB}dc_draw_planes,dc_draw_plane${TAB}"
want "clear_planes" "$W/ledger-render.tsv" "^Renderer#clear_planes${TAB}migrated${TAB}dc_clear_planes${TAB}"
want "the renderer's fixed_div, as the 0007 extraction" "$W/ledger-render.tsv" "^Renderer#fixed_div${TAB}migrated${TAB}fixed_div${TAB}"
want "draw_sky_plane, the sky drawn as texture columns" "$W/ledger-render.tsv" "^Renderer#draw_sky_plane${TAB}migrated${TAB}dc_draw_sky_plane,unreached-path:trace:trace-column-call,unreached-path:jobs:source-base${TAB}"
want "and emit_column, the job path, unreached in configuration jobs" "$W/ledger-render.tsv" "^Renderer#emit_column${TAB}unreached${TAB}unreached-in-config:jobs${TAB}"
want "the interval-table checks, the strict raises in the spine's check" "$W/ledger-render.tsv" "^Jobs#check_disjoint${TAB}unreached${TAB}unreached-in-config:jobs${TAB}"
want "and the last of them" "$W/ledger-render.tsv" "^Jobs#check_wall_all${TAB}unreached${TAB}unreached-in-config:jobs${TAB}"
want "the wall push" "$W/ledger-render.tsv" "^Jobs#push_wall${TAB}unreached${TAB}unreached-in-config:jobs${TAB}"
want "the masked push, fuzz columns through it too" "$W/ledger-render.tsv" "^Jobs#push_masked${TAB}unreached${TAB}unreached-in-config:jobs${TAB}"
want "the phase-3 mark" "$W/ledger-render.tsv" "^Jobs#mark_phase3${TAB}unreached${TAB}unreached-in-config:jobs${TAB}"
want "the ring's slot allocator, ported earlier" "$W/ledger-render.tsv" "^Jobs#alloc_zone_window${TAB}unreached${TAB}unreached-in-config:jobs${TAB}"
want "and the per-frame reset, ported earlier" "$W/ledger-render.tsv" "^Jobs#reset${TAB}unreached${TAB}unreached-in-config:jobs${TAB}"
want "the executor's run, into the schedule walk and the spine's run" "$W/ledger-render.tsv" "^JobExecutor#run${TAB}unreached${TAB}unreached-in-config:jobs${TAB}"
want "and the masked column, fuzz included" "$W/ledger-render.tsv" "^JobExecutor#exec_masked${TAB}unreached${TAB}unreached-in-config:jobs${TAB}"
want "Jobs#check, which the original's run calls first, ported into the spine" "$W/ledger-render.tsv" "^Jobs#check${TAB}unreached${TAB}unreached-in-config:jobs${TAB}"

section "the BSP walk, without recursion"
# CORE refuses recursion, so the two BSP walks become an explicit stack. What
# is compared is not only the ANSWER but the VISIT ORDER: 0008 says reversing
# a push order can change the image even when all nodes are visited, so an
# answer that agreed while the order did not would be agreeing by accident on
# this map and not on the next one.
# The IWAD comes from WAD or from the checkout, and from nowhere else: a
# path outside the checkout would make these lanes depend on one host.
WADFILE="${WAD:-$ROOT/build/doom-wad/doom1.wad}"
if [ ! -f "$WADFILE" ]; then
  skipped "the BSP lane" "no IWAD" "WAD=/path/to/doom1.wad (tools/doom/fetch-iwad.sh gets one)"
else
  "$RUBY" "$ROOT/tests/doom-core/bsp-model.rb" "$WADFILE" E1M1 > "$W/bsp.out" 2>&1 || true
  bsp() { grep "^$1 " "$W/bsp.out" | head -1 | cut -d" " -f2-; }
  ok "E1M1's real BSP tree is walked"        "$(bsp nodes)" "236"
  ok "four hundred traces agree"             "$(bsp agree)" "400"
  ok "and none differs"                      "$(bsp differ)" "0"
  ok "a stack too small reports CAPACITY"    "$(bsp capacity)" "capacity"
  # THE ORACLE IS THE ORIGINAL, and this is what says so: a raise injected into
  # `Doom::Sight#sight_divline_side` must reach the comparison. The old model
  # transcribed the predicate and both sides shared the copy, so 400/400 was
  # two routines agreeing with each other.
  ok "the oracle is sight.rb itself"         "$(bsp reaches-original)" "true"
  # The on-the-line answer, which 400 random pairs never reach because it needs
  # an exact coordinate equality. This is the one-node case from Mac review.
  ok "on the line answers 2, not a side"     "$(bsp online-side)" "1 2"
  ok "and the original visits the far child" "$(bsp online-original)" "false [0, 32769, 32768]"
  ok "the port visits it too"                "$(bsp online-ported)" "false [0, 32769, 32768]"
  ok "folding that answer away changes it"   "$(bsp folded-ported)" "true [0, 32769]"
  ok "so the control does differ"            "$(bsp folded-differs)" "true"
  # The same on a second map, so the agreement is not a property of one tree.
  "$RUBY" "$ROOT/tests/doom-core/bsp-model.rb" "$WADFILE" E1M3 > "$W/bsp3.out" 2>&1 || true
  ok "and on a different map"                "$(grep '^differ ' "$W/bsp3.out" | cut -d' ' -f2)" "0"
fi

section "the renderer's own BSP descent"
# Mac review of 33da4d9: `Renderer#render_bsp_node`'s work after `check_bbox`
# was neither implemented nor compared. The descent is compared now, against
# `Doom::Renderer#render_bsp_node` itself. `check_bbox` is NOT ported -- it
# needs point_to_angle, the viewangletox table and the solidsegs clip list --
# so both sides call one controlled gate and this compares the traversal
# around it. That limit is in the model's header and in
# docs/core/doom-closure-gaps.md, not left for a reader to infer.
if [ -f "$WADFILE" ]; then
  "$RUBY" "$ROOT/tests/doom-core/render-model.rb" "$WADFILE" E1M1 > "$W/rnd2.out" 2>&1 || true
  rd() { grep "^$1 " "$W/rnd2.out" | head -1 | cut -d" " -f2-; }
  ok "the oracle is render.rb itself"        "$(rd reaches-original)" "true"
  ok "four hundred views agree"              "$(rd agree)" "400"
  ok "and none differs"                      "$(rd differ)" "0"
  ok "a stack too small reports CAPACITY"    "$(rd capacity)" "capacity"
  # The harness is live: an inverted side predicate must change every walk.
  ok "an inverted predicate changes them all" "$(rd inverted-predicate-differs)" "40"
  # AND A MEASUREMENT, not a claim. `dc_sight_side` and `dc_point_on_side` are
  # different functions, but whether that shows in THIS walk is a question
  # about the map. Measured: on E1M1 it does not show at all.
  ok "the sight predicate is indistinguishable here" "$(rd folded-sight-differs)" "0"
  "$RUBY" "$ROOT/tests/doom-core/render-model.rb" "$WADFILE" E1M3 > "$W/rnd23.out" 2>&1 || true
  ok "and on a different map"                "$(grep '^differ ' "$W/rnd23.out" | cut -d' ' -f2)" "0"
fi

section "sound propagation, without recursion"
# The original recurses from INSIDE a loop over the sector's lines and
# continues that loop when the call returns, so a frame remembers where the
# loop was. A stack of sectors alone would restart each loop from zero.
if [ -f "$WADFILE" ]; then
  "$RUBY" "$ROOT/tests/doom-core/sound-model.rb" "$WADFILE" E1M1 > "$W/snd.out" 2>&1 || true
  snd() { grep "^$1 " "$W/snd.out" | head -1 | cut -d" " -f2-; }
  ok "E1M1's 85 sectors"                  "$(snd sectors)" "85"
  ok "sixty alerts agree"                 "$(snd agree)" "60"
  ok "and none differs"                   "$(snd differ)" "0"
  ok "a stack too small reports CAPACITY" "$(snd capacity)" "capacity"
  # Same two controls. The raise says the oracle is enemy.rb; the corrupted
  # `dc_sound_other` says the two sides no longer share one helper -- it used
  # to be called by both, so breaking it moved them together and 60/60 stood.
  ok "the oracle is enemy.rb itself"      "$(snd reaches-original)" "true"
  ok "corrupting dc_sound_other is seen"  "$(snd broken-other-caught)" "57"
  "$RUBY" "$ROOT/tests/doom-core/sound-model.rb" "$WADFILE" E1M3 > "$W/snd3.out" 2>&1 || true
  ok "and on a different map"             "$(grep '^differ ' "$W/snd3.out" | cut -d' ' -f2)" "0"
fi

# MUTATION-VERIFIED. Each of these checks was measured to be the one that
# fails, against the unit restored to its pinned hash afterwards:
#
#   dc_p_random reads at the OLD index (2 lines; dc_m_random byte-identical)
#     -> 4 fail: the model's mismatch count reads 2979, the native stream
#        differs, and the swap lane's value agreement breaks
#   the pcount increment is dropped
#     -> 4 fail: both counters, `cleared`, the native stream, and `counts 0 16`
#   dc_clear_random zeroes the counters too (4 lines, signature and all)
#     -> 2 fail: `cleared` reads 0 0 0 0, and the native `after` line
#   the fixture manifest's hash drifts from sources.tsv
#     -> 7 fail, the first naming the two digests that disagree
#
section "the random stream, which every demo comparison rests on"
"$RUBY" "$ROOT/tests/doom-core/random-model.rb" > "$W/rnd.out" 2>&1 || true
rnd() { grep "^$1 " "$W/rnd.out" | head -1 | cut -d" " -f2-; }
ok "four thousand draws, none mismatching" "$(rnd mismatch)" "0"
ok "and both indices land where the original's do" "$(rnd prndindex)" "163 163"
ok "and so do both counters" "$(rnd pcount)" "2979 2979"
ok "clearing the indices does not clear the counters" "$(rnd cleared)" "0 0 2979 1341"

section "injected omissions, reorderings and swaps"
# 0008 task 6 asks for these. What they measured is worth stating: the VALUE
# STREAM ALONE IS NOT ENOUGH. Both indices start at zero and walk the same
# table, so using the wrong generator throughout gives the same values -- the
# counters are what tell them apart, which is why they are state in the schema
# and not instrumentation.
want "an omitted draw diverges, and shortens the stream" "$W/rnd.out" \
  '^omitted values-diverge-at-300 counts-differ lengths 600/599$'
want "a reordered pair diverges at the pair"             "$W/rnd.out" \
  '^reordered values-diverge-at-100 counts-agree lengths 600/600$'
want "and the wrong generator is caught by the counters" "$W/rnd.out" \
  '^swapped values-agree counts-differ lengths 600/600$'

section "the random trace changes nothing the game sees"
# Random's trace fields are eliminated from the schema as reference-only
# (tools/doom/core-fields.tsv). That rests on the ORIGINAL: with the trace off
# and on, the same draws give the same values and the same four state fields;
# only log_n differs. And the port agrees with the untraced original.
ok "trace off: the port's values and counters agree" \
   "$(grep '^trace off ' "$W/rnd.out")" "trace off log_n 0 port-values agree port-counts agree"
ok "a bank full at once changes nothing" "$(grep '^trace cap 0 ' "$W/rnd.out")" "trace cap 0 values agree state agree log_n 0"
ok "nor one full after a draw" "$(grep '^trace cap 1 ' "$W/rnd.out")" "trace cap 1 values agree state agree log_n 1"
ok "nor a capacity-64 bank, which the 160 game draws saturate" "$(grep '^trace cap 64 ' "$W/rnd.out")" "trace cap 64 values agree state agree log_n 64"
ok "over draws that start where a cleared generator starts" "$(grep '^trace first ' "$W/rnd.out")" \
   "trace first values 8,8,109 state 160,40,160,40"
# AND IT WOULD SEE A TRACE THAT DID: a copy of the original whose trace branch
# also advances pcount.
mkdir -p "$W/trc/examples/doom/lib/doom" "$W/trc/examples/doom/core/src" "$W/trc/tests/doom-core" "$W/trc/tools/core"
cp "$ROOT/examples/doom/core/src/random.rb" "$W/trc/examples/doom/core/src/random.rb"
cp "$ROOT/tests/doom-core/random-model.rb" "$W/trc/tests/doom-core/random-model.rb"
cp "$ROOT/tools/core/intrinsics.rb" "$W/trc/tools/core/intrinsics.rb"
sed 's|^        @log_n = n + 1$|        @log_n = n + 1; @pcount += 1|' \
  "$ROOT/examples/doom/lib/doom/random.rb" > "$W/trc/examples/doom/lib/doom/random.rb"
ok "the mutation is one line" \
   "$(diff "$ROOT/examples/doom/lib/doom/random.rb" "$W/trc/examples/doom/lib/doom/random.rb" | grep -c '^[<>]')" "2"
"$RUBY" "$W/trc/tests/doom-core/random-model.rb" > "$W/trc.out" 2>&1 || true
ok "a trace that touched a counter is caught" "$(grep '^trace cap 64 ' "$W/trc.out")" \
   "trace cap 64 values agree state differ log_n 64"

section "the same stream from a CORE object"
if [ ! -x "$KERNEL" ] || [ -z "$CC_BIN" ] || [ ! -x "$CC_BIN" ]; then
  # Say so. Without this the lane vanishes and the only trace is a check count
  # nine lower than the one recorded in the commit message.
  skipped "the CORE lane" "no kernel or no compiler" "KERNEL=/path/to/spinel-core-kernel and LLVM_PREFIX=/path/to/llvm (or CLANG)"
else
  RND="$ROOT/tests/doom-core/fixtures/random"
  mkdir -p "$W/rndsrc/src" "$W/rndunit"
  # THE FIXTURE DOES NOT CARRY A COPY of the generator. It stages the unit
  # itself -- examples/doom/core/src/random.rb -- beside an entry wrapper, and
  # the fixture manifest pins the SAME sha256 that examples/doom/core/sources.tsv
  # pins. Editing the unit and forgetting either one fails here, which a copy
  # in the fixture would have hidden by compiling the stale twin.
  cp "$ROOT/examples/doom/core/src/random.rb" "$W/rndunit/random.rb"
  cp "$RND/src/entries.rb" "$W/rndunit/entries.rb"
  ok "the fixture pins the unit's own hash" \
    "$(awk -F"\t" '$1 == "random.rb" { print $2 }' "$RND/manifest.tsv")" \
    "$(awk -F"\t" '$1 == "random.rb" { print $2 }' "$ROOT/examples/doom/core/sources.tsv")"
  "$RUBY" "$PACK" --manifest "$RND/manifest.tsv" --root "$W/rndunit" \
    --reader "$READER" --output "$W/rndsrc/src/packed.rb" --map "$W/rndsrc/map.tsv" \
    > "$W/rndpack.err" 2>&1 && echo 0 > "$W/rndpack.rc" || echo $? > "$W/rndpack.rc"
  ok "the generator packs" "$(cat "$W/rndpack.rc")" 0
  cp "$RND/pr.contract" "$W/rndsrc/pr.contract"
  for e in pr mr cr; do
    cp "$RND/$e.contract" "$W/rndsrc/$e.contract"
    "$KERNEL" "$W/rndsrc/$e.contract" --root "$W/rndsrc" --typedump "$READER" -o "$W/$e.o" \
      --header "$W/$e.h" --clang "$CC_BIN" > "$W/$e.err" 2>&1 \
      && echo 0 > "$W/$e.rc" || echo $? > "$W/$e.rc"
    ok "$e compiles as a core object" "$(cat "$W/$e.rc")" 0
  done
  # The expected stream comes from `Doom::Random` itself, not from a constant
  # typed in here: the same interleaving the C driver below makes, run against
  # the original, and written out for a byte comparison.
  "$RUBY" -e '
    require_relative File.join(ARGV[0], "examples/doom/lib/doom/random")
    t = Doom::Random::RNDTABLE.bytes
    r = Doom::Random.new; r.clear
    v = (0...24).map { |i| i % 3 == 0 ? r.m_random : r.p_random(0) }
    File.write(ARGV[1], "static const unsigned char table[256] = {#{t.join(",")}};\n")
    r.clear
    print "#{v.join(" ")}\nafter #{r.prndindex} #{r.rndindex} #{r.pcount} #{r.mcount}\n"
  ' "$ROOT" "$W/table.h" > "$W/ruby-stream.txt"
  cat > "$W/pr.c" <<'CEOF'
#include <stdio.h>
#include <stdint.h>
#include "pr.h"
#include "mr.h"
#include "cr.h"
#include "table.h"
int main(void) {
  int64_t prnd[1] = {0}, rnd[1] = {0}, pc[1] = {0}, mc[1] = {0}, r;
  for (int i = 0; i < 24; i++) {
    if (i % 3 == 0) spinel_core_dc_mr((const uint8_t*)table, 256, rnd, 1, mc, 1, &r);
    else            spinel_core_dc_pr((const uint8_t*)table, 256, prnd, 1, pc, 1, &r);
    printf("%s%lld", i ? " " : "", (long long)r);
  }
  /* Clearing resets both indices and NEITHER counter -- the property the
     whole schema decision rests on, checked in compiled code. */
  spinel_core_dc_cr(prnd, 1, rnd, 1, &r);
  printf("\nafter %lld %lld %lld %lld\n", (long long)prnd[0], (long long)rnd[0],
         (long long)pc[0], (long long)mc[0]);
  return 0;
}
CEOF
  if "$CC_BIN" -I"$W" "$W/pr.c" "$W/pr.o" "$W/mr.o" "$W/cr.o" -o "$W/pr" \
       > "$W/prlink.err" 2>&1; then
    ok "the native stream is the CRuby stream" "$("$W/pr")" "$(cat "$W/ruby-stream.txt")"
  else
    echo "  FAIL the core objects did not link"; sed 's/^/        /' "$W/prlink.err" | head -4
    fail=$((fail + 1))
  fi

  # THE SWAP, IN COMPILED CODE. Drawing from the wrong generator throughout
  # gives the SAME 24 values; only the counters differ. This is the same
  # measurement random-model.rb makes in CRuby, made again on the objects that
  # actually ship, because it is the reason `pcount` and `mcount` are state.
  cat > "$W/sw.c" <<'CEOF'
#include <stdio.h>
#include <stdint.h>
#include "pr.h"
#include "mr.h"
#include "table.h"
int main(void) {
  int64_t prnd[1] = {0}, rnd[1] = {0}, pc[1] = {0}, mc[1] = {0}, r;
  for (int i = 0; i < 24; i++) {
    if (i % 3 == 0) spinel_core_dc_pr((const uint8_t*)table, 256, prnd, 1, pc, 1, &r);
    else            spinel_core_dc_mr((const uint8_t*)table, 256, rnd, 1, mc, 1, &r);
    printf("%s%lld", i ? " " : "", (long long)r);
  }
  printf("\ncounts %lld %lld\n", (long long)pc[0], (long long)mc[0]);
  return 0;
}
CEOF
  if "$CC_BIN" -I"$W" "$W/sw.c" "$W/pr.o" "$W/mr.o" -o "$W/sw" > "$W/swlink.err" 2>&1; then
    ok "swapping the generators changes not one value" \
      "$("$W/sw" | head -1)" "$(head -1 "$W/ruby-stream.txt")"
    ok "and the counters are what catch it" \
      "$("$W/sw" | tail -1)" "counts 8 16"
    ok "against the honest run's own counters" \
      "$(sed -n 's/^after [0-9]* [0-9]* //p' "$W/ruby-stream.txt")" "16 8"
  else
    echo "  FAIL the swap driver did not link"; sed 's/^/        /' "$W/swlink.err" | head -4
    fail=$((fail + 1))
  fi
fi

section "RES_ZONE's two stores: kept, and actually read"
# docs/core/doom-source-alias.md, prerequisite C, on the ORIGINAL over DEMO1,
# with test-side hooks that watch the consumers' own reads: every source byte
# the executor (job mode 2) or render.rb's draw_column (job mode 0) reads for a
# zone window is recorded against a consumption expected where the window was
# produced. Controls change one line in a PRIVATE COPY of the game library,
# never the tree. Job mode 4, where the GPU reads the ring, is NOT covered.
if [ ! -f "$WADFILE" ]; then
  skipped "the zone ring lane" "no IWAD" "WAD=/path/to/doom1.wad (tools/doom/fetch-iwad.sh gets one)"
else
  ZR="$ROOT/tests/doom-core/zone-ring.rb"
  zr() { # out mode [lib]
    if [ -n "${3:-}" ]; then
      ZONE_RING_LIB="$3" "$RUBY" "$ZR" "$WADFILE" "$2" 200 > "$W/zr-$1.out" 2>&1 || true
    else
      "$RUBY" "$ZR" "$WADFILE" "$2" 200 > "$W/zr-$1.out" 2>&1 || true
    fi
  }
  zrlib() { # name file old new -- a copy of the library with one change
    cp -R "$ROOT/examples/doom/lib/doom" "$W/zrlib-$1"
    "$RUBY" -e 'f, a, b = ARGV; s = File.read(f); s.scan(a).length == 1 or abort("anchor"); File.write(f, s.sub(a) { b })' \
      "$W/zrlib-$1/$2" "$3" "$4"
  }
  zrlib exec-store executor.rb '      use_zone_ring = @masked[b + Jobs::MC_SRCRES] == Jobs::RES_ZONE' '      use_zone_ring = false'
  zrlib exec-slot executor.rb '      ofs = @masked[b + Jobs::MC_SRCOFS]' '      ofs = @masked[b + Jobs::MC_SRCOFS] + 128'
  zrlib exec-off1 executor.rb '      ofs = @masked[b + Jobs::MC_SRCOFS]' '      ofs = @masked[b + Jobs::MC_SRCOFS] + 1'
  zrlib exec-skip executor.rb '    def exec_masked(i, scr)
      b = i * Jobs::MC_NF
' '    def exec_masked(i, scr)
      b = i * Jobs::MC_NF
      return if @masked[b + Jobs::MC_SRCRES] == Jobs::RES_ZONE
'
  zrlib direct-store render.rb '        source_byte = use_zone_window ? @zonewin.getbyte(source_index) : buf.getbyte(source_index)' '        source_byte = use_zone_window ? @wad_data.getbyte(source_index) : buf.getbyte(source_index)'
  zrlib direct-off1 render.rb '            use_zone_window = true
            @dc_srcofs = 0' '            use_zone_window = true
            @dc_srcofs = 1'
  ok "each control library differs from the tree in one place" \
     "$(for c in exec-store exec-slot exec-off1 exec-skip direct-store direct-off1; do diff -r "$ROOT/examples/doom/lib/doom" "$W/zrlib-$c" | grep -c '^[<>]'; done | tr '\n' ' ')" \
     "2 2 2 1 2 2 "
  zr queued queued; zr direct direct; zr paired paired
  zr reset-early reset-early; zr same-slot same-slot
  zr exec-store queued "$W/zrlib-exec-store"; zr exec-slot queued "$W/zrlib-exec-slot"
  zr exec-skip queued "$W/zrlib-exec-skip"; zr exec-off1 paired "$W/zrlib-exec-off1"
  zr direct-store direct "$W/zrlib-direct-store"; zr direct-off1 paired "$W/zrlib-direct-off1"
  "$RUBY" "$ZR" "$WADFILE" capacity > "$W/zr-capacity.out" 2>&1 || true
  CLEAN="faults wrong-store 0 out-of-window 0 wrong-count 0 stale-bytes 0 not-consumed 0"
  ok "queued: every zone job is read from its own ring slot, slot 0 and others" \
     "$(sed -n 1,2p "$W/zr-queued.out" | tr '\n' '|')" \
     "frames 200 zone-jobs 8229 nonzero-slots 8038 consumed 8229|$CLEAN|"
  ok "direct: every masked-column window is read from @zonewin at 0" \
     "$(sed -n 1,2p "$W/zr-direct.out" | tr '\n' '|')" \
     "tics 200 windows 8239 consumed 8229 fuzz-or-empty 10|$CLEAN|"
  ok "and the two consumers read the same bytes of their windows, pixel for pixel" \
     "$(sed -n 1,2p "$W/zr-paired.out" | tr '\n' '|')" "paired queued 8229 direct 8229 differ 0|$CLEAN|"
  # The controls, each by the fault it must produce and where it first appears.
  zf() { printf '%s|%s' "$(sed -n 2p "$W/zr-$1.out" | sed "s/.* $2 \([0-9]*\).*/\1/")" "$(sed -n 3p "$W/zr-$1.out")"; }
  ok "a ring rewound before its jobs run: stale bytes" "$(zf reset-early stale-bytes)" "7973|first stale-bytes frame 0 job 12 slot 0"
  ok "one slot for every window: stale bytes" "$(zf same-slot stale-bytes)" "7982|first stale-bytes frame 0 job 12 slot 0"
  ok "an executor that reads the WAD data instead: wrong store" "$(zf exec-store wrong-store)" "8229|first wrong-store frame 0 job 12 slot 0"
  ok "an executor that reads the next slot: out of window" "$(zf exec-slot out-of-window)" "8229|first out-of-window frame 0 job 12 slot 0"
  ok "an executor that skips zone jobs: no reads where some were expected" "$(zf exec-skip wrong-count)" "8229|first wrong-count frame 0 job 12 slot 0"
  ok "a direct column that reads the WAD data instead: wrong store" "$(zf direct-store wrong-store)" "8229|first wrong-store tic 0 x 96"
  ok "a base one byte off in the executor: the consumers disagree" \
     "$(sed -n 1p "$W/zr-exec-off1.out")|$(sed -n 3p "$W/zr-exec-off1.out")" \
     "paired queued 8229 direct 8229 differ 8229|first frame 0 job 12 slot 0 / tic 0 x 96"
  ok "and in the direct column" \
     "$(sed -n 1p "$W/zr-direct-off1.out")|$(sed -n 3p "$W/zr-direct-off1.out")" \
     "paired queued 8229 direct 8229 differ 8229|first frame 0 job 12 slot 0 / tic 0 x 96"
  ok "the ring's last valid slot is the 3072nd, at 393088" \
     "$(head -1 "$W/zr-capacity.out")" "capacity slots 3072 last 393088 last-expected 393088 nzone 3072"
  ok "and the first invalid one is refused by name, not wrapped" \
     "$(sed -n 2p "$W/zr-capacity.out")" "overflow zone window ring overflow: 3072 windows, ZONE_SLOTS=3072"
  # ONE RING. The executor must keep the actual Jobs owner, not a copy.
  # The five array-bank aliases remain checked against the schema.
  zrlib exec-dup executor.rb '      @jobs = jobs' '      @jobs = jobs.dup'
  ok "the executor keeps Jobs' owner and its five schema bank aliases" \
     "$("$RUBY" "$ROOT/tests/doom-core/zone-alias.rb" "$ROOT/examples/doom/lib/doom" 2>&1)" "aliases 5 identical; ring owner identical"
  ok "and an executor holding a copied owner is refused" \
     "$(diff -r "$ROOT/examples/doom/lib/doom" "$W/zrlib-exec-dup" | grep -c '^[<>]')|$("$RUBY" "$ROOT/tests/doom-core/zone-alias.rb" "$W/zrlib-exec-dup" 2>&1)" \
     "2|aliases refused JobExecutor@@jobs is not the Jobs owner of jobs_zonebuf"
fi

if stage1_lanes_run; then
section "the source selector and base: CORE producers and consumers in the game"
# docs/core/doom-source-alias.md: examples/doom/core/src/source.rb replaces the
# buffer references with a selector and a base. tests/doom-core/source-port.rb
# adds its producers beside the original's in a PRIVATE COPY of render.rb and
# runs its consumers beside the original's drawing, over DEMO1, in job mode 0
# and 2. 600 tics, because the first sky column is at tic 572. Each control
# removes one producer line (or hands the queued masked consumer the wrong
# store) and must fault at the site it removed. Job mode 4 is NOT covered.
if [ ! -f "$WADFILE" ]; then
  skipped "the source port lane" "no IWAD" "WAD=/path/to/doom1.wad (tools/doom/fetch-iwad.sh gets one)"
else
  SP="$ROOT/tests/doom-core/source-port.rb"
  sp() { # mode tics control
    rc=0; "$RUBY" "$SP" "$WADFILE" "$1" "$2" "$3" > "$W/sp-$1-$3.out" 2>&1 || rc=$?
    echo "rc=$rc" >> "$W/sp-$1-$3.out"
  }
  spo() { tr '\n' '|' < "$W/sp-$1-$2.out"; }
  for c in none no-sky; do sp direct 600 $c; sp queued 600 $c; done
  for c in no-wall skip-masked no-span; do sp direct 200 $c; sp queued 200 $c; done
  sp queued 200 queued-wrong-store; sp direct 200 queued-wrong-store
  PRE6="producers added 8 markers 3 pre-tick port -1 0 -1 0 original -1 0 -1 0|demo DEMO1 map E1M5 tics 5026"
  PRE5="producers added 7 markers 3 pre-tick port -1 0 -1 0 original -1 0 -1 0|demo DEMO1 map E1M5 tics 5026"
  D600="tics 600 columns 352285 spans 94425|sites masked=133337@tic0,sky=1296@tic572,wall=217652@tic0|masked remaining wad-min 128 zone-max 127 zone-windows 30904"
  Q600="frames 600 wall-jobs 222093 span-jobs 94425 masked-jobs 133337 zone-jobs 28141 resets 600 of 31+1 cells|sites masked=133337@frame0,sky=1296@frame572,wall=220797@frame0|masked remaining wad-min 128 zone-max 127 zone-windows 30904"
  D200="tics 200 columns 118099 spans 33540|sites masked=37586@tic0,wall=80513@tic0"
  Q200="frames 200 wall-jobs 82353 span-jobs 33540 masked-jobs 37586 zone-jobs 8229 resets 200 of 31+1 cells|sites masked=37586@frame0,wall=82353@frame0"
  REM="masked remaining wad-min 128 zone-max 127 zone-windows 8239"
  ok "direct: the port's selector and base are the original's converted, and draw its pixels, at every site" \
     "$(spo direct none)" "$PRE6|$D600|faults producer-disagree 0 unreadable-selector 0 pixel-mismatch 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0|first producer-disagree none|first unreadable-selector none|first pixel-mismatch none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|rc=0|"
  ok "queued: every wall, sky, span and masked job carries them, and the port draws the executor's pixels" \
     "$(spo queued none)" "$PRE6|$Q600|faults job-disagree 0 unreadable-selector 0 pixel-mismatch 0 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0|first job-disagree none|first unreadable-selector none|first pixel-mismatch none|first reset-disagree none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|rc=0|"
  ok "no sky producer, direct: every sky column faults" \
     "$(spo direct no-sky)" "$PRE5|$D600|faults producer-disagree 1296 unreadable-selector 0 pixel-mismatch 1296 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0|first producer-disagree sky tic 572 x 106|first unreadable-selector none|first pixel-mismatch sky tic 572 x 106|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|rc=0|"
  ok "no sky producer, queued" \
     "$(spo queued no-sky)" "$PRE5|$Q600|faults job-disagree 1296 unreadable-selector 0 pixel-mismatch 1296 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0|first job-disagree sky frame 572 wall job 335|first unreadable-selector none|first pixel-mismatch sky frame 572 wall job 335 x 106|first reset-disagree none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|rc=0|"
  ok "no wall producer, direct" \
     "$(spo direct no-wall)" "$PRE5|$D200|$REM|faults producer-disagree 80513 unreadable-selector 616 pixel-mismatch 79632 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0|first producer-disagree wall tic 0 x 261|first unreadable-selector wall tic 0 x 261 selector -1|first pixel-mismatch wall tic 1 x 261|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|rc=0|"
  ok "no wall producer, queued: a wall job's context reads only the atlas" \
     "$(spo queued no-wall)" "$PRE5|$Q200|$REM|faults job-disagree 82353 unreadable-selector 80513 pixel-mismatch 0 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0|first job-disagree wall frame 0 wall job 0|first unreadable-selector wall frame 0 wall job 0 x 261 selector -1|first pixel-mismatch none|first reset-disagree none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|rc=0|"
  ok "no masked producer, direct" \
     "$(spo direct skip-masked)" "$PRE5|$D200|masked remaining wad-min - zone-max - zone-windows 8239|faults producer-disagree 37586 unreadable-selector 0 pixel-mismatch 37551 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0|first producer-disagree masked tic 0 x 175|first unreadable-selector none|first pixel-mismatch masked tic 0 x 175|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|rc=0|"
  ok "no masked producer, queued" \
     "$(spo queued skip-masked)" "$PRE5|frames 200 wall-jobs 82353 span-jobs 33540 masked-jobs 37586 zone-jobs 0 resets 200 of 31+1 cells|sites masked=37586@frame0,wall=82353@frame0|masked remaining wad-min - zone-max - zone-windows 8239|faults job-disagree 37586 unreadable-selector 37586 pixel-mismatch 0 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0|first job-disagree masked frame 0 masked job 0|first unreadable-selector masked frame 0 masked job 0 x 175 selector 0|first pixel-mismatch none|first reset-disagree none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|rc=0|"
  ok "no span producer, direct" \
     "$(spo direct no-span)" "$PRE5|$D200|$REM|faults producer-disagree 33540 unreadable-selector 33540 pixel-mismatch 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0|first producer-disagree span tic 0 y 130|first unreadable-selector span tic 0 y 130 selector -1|first pixel-mismatch none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|rc=0|"
  ok "no span producer, queued" \
     "$(spo queued no-span)" "$PRE5|$Q200|$REM|faults job-disagree 33540 unreadable-selector 33540 pixel-mismatch 0 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0|first job-disagree span frame 0 span job 0|first unreadable-selector span frame 0 span job 0 y 130 selector -1|first pixel-mismatch none|first reset-disagree none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|rc=0|"
  ok "RES_ZONE read from the IWAD bytes instead of the ring: the zone jobs' pixels differ" \
     "$(spo queued queued-wrong-store)" "$PRE6|$Q200|$REM|faults job-disagree 0 unreadable-selector 0 pixel-mismatch 8223 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0|first job-disagree none|first unreadable-selector none|first pixel-mismatch masked frame 0 masked job 12 x 96|first reset-disagree none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|rc=0|"
  ok "and that control is refused where there is no queued consumer to change" \
     "$(spo direct queued-wrong-store)" "source-port.rb: queued-wrong-store changes the queued ring; it has nothing to change in direct|rc=1|"
  # THE ZONE WINDOWS ARE THE PORT'S OWN (examples/doom/core/src/zone.rb): each
  # window is written by the port's producer into the port's store, checked
  # byte for byte against the original's window and, queued, its slot against
  # the original's; the consumers read the port's stores. Without the producer
  # the columns read windows nobody wrote; with the queued producer writing a
  # SECOND ring, its own window is right and the executor's view is not.
  sp direct 200 no-zone; sp queued 200 no-zone; sp queued 200 zone-separate-ring; sp direct 200 zone-separate-ring
  ok "no zone producer, direct: every column reading a zone window draws wrong" "$(spo direct no-zone)" "producers added 6 markers 3 pre-tick port -1 0 -1 0 original -1 0 -1 0|demo DEMO1 map E1M5 tics 5026|tics 200 columns 118099 spans 33540|sites masked=37586@tic0,wall=80513@tic0|masked remaining wad-min 128 zone-max 127 zone-windows 0|faults producer-disagree 0 unreadable-selector 0 pixel-mismatch 8213 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0|first producer-disagree none|first unreadable-selector none|first pixel-mismatch masked tic 0 x 96|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|rc=0|"
  ok "no zone producer, queued" "$(spo queued no-zone)" "producers added 6 markers 3 pre-tick port -1 0 -1 0 original -1 0 -1 0|demo DEMO1 map E1M5 tics 5026|frames 200 wall-jobs 82353 span-jobs 33540 masked-jobs 37586 zone-jobs 8229 resets 200 of 31+1 cells|sites masked=37586@frame0,wall=82353@frame0|masked remaining wad-min 128 zone-max 127 zone-windows 0|faults job-disagree 0 unreadable-selector 0 pixel-mismatch 8213 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0|first job-disagree none|first unreadable-selector none|first pixel-mismatch masked frame 0 masked job 12 x 96|first reset-disagree none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|rc=0|"
  ok "the ring producer writing a second ring: its windows agree and the executor's pixels do not" "$(spo queued zone-separate-ring)" "producers added 8 markers 3 pre-tick port -1 0 -1 0 original -1 0 -1 0|demo DEMO1 map E1M5 tics 5026|frames 200 wall-jobs 82353 span-jobs 33540 masked-jobs 37586 zone-jobs 8229 resets 200 of 31+1 cells|sites masked=37586@frame0,wall=82353@frame0|masked remaining wad-min 128 zone-max 127 zone-windows 8239|faults job-disagree 0 unreadable-selector 0 pixel-mismatch 8213 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0|first job-disagree none|first unreadable-selector none|first pixel-mismatch masked frame 0 masked job 12 x 96|first reset-disagree none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|rc=0|"
  # JOBS#RESET IS THE PORT'S TOO, its table read off the original's reset: a
  # table without the ring's counter is caught at the first frame that needs it.
  sp queued 200 reset-drop-nzone
  ok "a reset table without the ring's counter" "$(spo queued reset-drop-nzone)" "producers added 8 markers 3 pre-tick port -1 0 -1 0 original -1 0 -1 0|demo DEMO1 map E1M5 tics 5026|frames 200 wall-jobs 82353 span-jobs 33540 masked-jobs 37586 zone-jobs 8229 resets 200 of 31+1 cells|sites masked=37586@frame0,wall=82353@frame0|masked remaining wad-min 128 zone-max 127 zone-windows 8239|faults job-disagree 0 unreadable-selector 0 pixel-mismatch 8117 reset-disagree 199 zone-disagree 0 zone-slot-disagree 8234 zone-capacity 5167|first job-disagree none|first unreadable-selector none|first pixel-mismatch masked frame 7 masked job 12 x 96|first reset-disagree frame 1 jobs_nzone 5 original 0|first zone-disagree none|first zone-slot-disagree masked tic 1 lump 987 off 556 slot 640 original 0|first zone-capacity masked tic 130 lump 576 off 49|rc=0|"
  ok "and that control is refused where there is no ring" "$(spo direct zone-separate-ring)" \
     "source-port.rb: zone-separate-ring changes the queued ring; it has nothing to change in direct|rc=1|"

  # THE FRAME LANE IS NOT IN THIS FILE. The job banks, their checks, the
  # executor and the 600-frame screen comparison are declared as cases in
  # tests/doom-core/cases/frame.tsv and run by tests/doom-core/harness/run.rb,
  # which judges each run's result record against tests/doom-core/expect/.
  # See the 2026-09-15 clarification in docs/decisions/0009-doom-core-test-harness.md.
  #
  # What stays here is the refusal below: a control that changes the port's
  # frame-mode pushes, checks or run has nothing to change in queued mode, and
  # says so rather than running and passing vacuously. The other two parts of
  # this check moved with the lane.
  sp queued 60 frame-order; sp queued 60 plane-skip
  ok "a frame, push, check or plane control is refused outside frame mode" \
     "$(spo queued frame-order)$(spo queued plane-skip)" \
     "source-port.rb: frame-order changes the port's frame-mode pushes, checks or run; it has nothing to change in queued|rc=1|source-port.rb: plane-skip changes the port's frame-mode pushes, checks or run; it has nothing to change in queued|rc=1|"
fi

section "the source selector and base: compiled CORE entries"
# The same port, compiled. tests/doom-core/fixtures/source/ declares thirty-nine
# entries over it -- the three consumers, the four producers, the zone window,
# the ring's allocator, Jobs#reset, the executor's whole run, the three pushes,
# the two phase marks, the four interval-table checks, the whole plane walk with
# its sky plane and the per-plane body it calls, clear_planes, the status bar,
# the HUD's message line and eleven of the renderer's leaves -- and the
# kernel tool builds each from the units themselves, never a copy. Then:
#   * every buffer face of every entry at its edge (source-edges.rb, edges.c),
#     except the status bar's, the HUD's and the renderer leaves', which have
#     no edge cases yet:
#     the last valid index succeeds with what the Ruby port computes, one past
#     and one below are SPINEL_CORE_BOUNDS with nothing stored by that access
#     and no result, over allocations of exactly the declared count;
#   * the same cases under AddressSanitizer, with no report, and a caller lying
#     about the atlas's count reported from inside the compiled column, and one
#     lying about the flat atlas's from inside the compiled executor, and one
#     lying about a wall bank's from inside the compiled push;
#   * the entries in the game, over DEMO1, in place of the Ruby definitions
#     (SOURCE_PORT_NATIVE): the same comparisons as above, every call status 0;
#   * a column entry built from source.rb with one line changed fails both.
if [ ! -x "$KERNEL" ] || [ -z "$CC_BIN" ] || [ ! -x "$CC_BIN" ]; then
  skipped "the compiled source lane" "no kernel or no compiler" "KERNEL=/path/to/spinel-core-kernel and LLVM_PREFIX=/path/to/llvm (or CLANG)"
else
  SRCFIX="$ROOT/tests/doom-core/fixtures/source"
  LLVM_BIN=$(dirname -- "$CC_BIN")
  SENTRIES="col span mjob none tex mask flat zone zalloc jreset exec pwall pspan pmask ph1 ph3 cdis cspan cmask call dplanes cplanes sbdraw hudraw pangle pdist sgscale lindex absang clipv segside fplane chplane ssclear crunch chkbbox vssort addspr segloop"
  dc_artifacts_ready || die "the compiled source lane is missing a name the recipes read"
  ok "the fixture pins the units' own hashes" \
    "$(awk -F"\t" '$1 == "fixed.rb" || $1 == "source.rb" || $1 == "zone.rb" || $1 == "executor.rb" || $1 == "jobs.rb" || $1 == "checks.rb" || $1 == "planespan.rb" || $1 == "planes.rb" || $1 == "statusbar.rb" || $1 == "hud.rb" || $1 == "leaves.rb" || $1 == "segs.rb" { print $1, $2 }' "$SRCFIX/manifest.tsv")" \
    "$(awk -F"\t" '$1 == "fixed.rb" || $1 == "source.rb" || $1 == "zone.rb" || $1 == "executor.rb" || $1 == "jobs.rb" || $1 == "checks.rb" || $1 == "planespan.rb" || $1 == "planes.rb" || $1 == "statusbar.rb" || $1 == "hud.rb" || $1 == "leaves.rb" || $1 == "segs.rb" { print $1, $2 }' "$ROOT/examples/doom/core/sources.tsv")"
  dc_entry_units "$W/sk"
  rc=0; dc_entries "$W/sk" "$W/sk/unit" || rc=$?
  ok "all thirty-nine entries compile as core objects" "$rc" 0
  if [ "$rc" -eq 0 ]; then
    ok "with no undefined symbol and one export each" \
      "$(for e in $SENTRIES; do printf '%s:%s:%s ' "$e" "$("$LLVM_BIN/llvm-nm" -u "$W/sk/$e.o" | wc -l | tr -d ' ')" "$("$LLVM_BIN/llvm-nm" -g --defined-only "$W/sk/$e.o" | wc -l | tr -d ' ')"; done)" \
      "col:0:1 span:0:1 mjob:0:1 none:0:1 tex:0:1 mask:0:1 flat:0:1 zone:0:1 zalloc:0:1 jreset:0:1 exec:0:1 pwall:0:1 pspan:0:1 pmask:0:1 ph1:0:1 ph3:0:1 cdis:0:1 cspan:0:1 cmask:0:1 call:0:1 dplanes:0:1 cplanes:0:1 sbdraw:0:1 hudraw:0:1 pangle:0:1 pdist:0:1 sgscale:0:1 lindex:0:1 absang:0:1 clipv:0:1 segside:0:1 fplane:0:1 chplane:0:1 ssclear:0:1 crunch:0:1 chkbbox:0:1 vssort:0:1 addspr:0:1 segloop:0:1 "
    # Linking them into a shared object for the game run leaves nothing for the
    # linker to decide: every relocation is a branch to text defined in the same
    # object (tests/doom-core/object-relocs.rb). How many there are is the
    # platform's: none on Debian x86_64, where the wrapper's call to its body is
    # resolved when assembled; one ARM64_RELOC_BRANCH26 to that body on macOS.
    OR="$ROOT/tests/doom-core/object-relocs.rb"
    "$RUBY" "$OR" "$LLVM_BIN" $(for e in $SENTRIES; do printf '%s ' "$W/sk/$e.o"; done) > "$W/relocs.out" 2>&1 \
      && echo 0 >> "$W/relocs.out" || echo "rc=$?" >> "$W/relocs.out"
    ok "and nothing left for a linker but branches into their own code" \
      "$(grep -v '^targets ' "$W/relocs.out" | tr '\n' ' ')" "col ok span ok mjob ok none ok tex ok mask ok flat ok zone ok zalloc ok jreset ok exec ok pwall ok pspan ok pmask ok ph1 ok ph3 ok cdis ok cspan ok cmask ok call ok dplanes ok cplanes ok sbdraw ok hudraw ok pangle ok pdist ok sgscale ok lindex ok absang ok clipv ok segside ok fplane ok chplane ok ssclear ok crunch ok chkbbox ok vssort ok addspr ok segloop ok 0 "
    # The rule's own controls, on objects compiled here: a branch to a function
    # of the same object is admitted; a branch to an undefined one, a
    # PC-relative data reference and an unwind record are each refused.
    mkdir -p "$W/rel"
    printf '__attribute__((noinline)) int h(int x) { return x + 1; }\nint g(int x) { return h(x) * 2; }\n' > "$W/rel/self.c"
    printf 'int f(void);\nint g(void) { return f(); }\n' > "$W/rel/external.c"
    printf 'static const unsigned char t[4] = {1, 2, 3, 4};\n__attribute__((noinline)) int g(int i) { return t[i & 3]; }\n' > "$W/rel/data.c"
    printf 'int k(int x) { return x + 1; }\n' > "$W/rel/unwind.c"
    for c in self external data; do
      "$CC_BIN" -O1 -ffunction-sections -fno-asynchronous-unwind-tables -fno-unwind-tables -c "$W/rel/$c.c" -o "$W/rel/$c.o"
    done
    "$CC_BIN" -O1 -funwind-tables -c "$W/rel/unwind.c" -o "$W/rel/unwind.o"
    ok "the rule admits a branch to its own function and refuses a call out, data and unwind records" \
      "$(for c in self external data unwind; do "$RUBY" "$OR" "$LLVM_BIN" "$W/rel/$c.o" 2>&1 | grep -v '^targets ' | cut -d' ' -f1-2; done | tr '\n' ' ')" \
      "self ok external refused data refused unwind refused "
    SE="$ROOT/tests/doom-core/source-edges.rb"
    "$RUBY" "$SE" cases "$W/se-cases.txt" > "$W/se.err" 2>&1 && "$RUBY" "$SE" expected "$W/se-expected.txt" >> "$W/se.err" 2>&1 \
      && echo 0 > "$W/se.rc" || echo $? > "$W/se.rc"
    ok "the edge cases are generated, each pair one edit apart, each success run in CRuby" "$(cat "$W/se.rc")" 0
    "$CC_BIN" -std=c11 -Wall -Wextra -Werror -O1 -I"$W/sk" "$SRCFIX/edges.c" "$W/sk"/*.o -o "$W/se-edges" > "$W/se-cc.err" 2>&1 \
      && echo 0 > "$W/se-cc.rc" || echo $? > "$W/se-cc.rc"
    ok "the edge harness links against them" "$(cat "$W/se-cc.rc")" 0
    "$W/se-edges" < "$W/se-cases.txt" > "$W/se-got.txt" 2>&1 || true
    ok "every face's last index succeeds, one past and one below are BOUNDS, one past an i64 edge is ARITHMETIC" \
      "$(cmp -s "$W/se-expected.txt" "$W/se-got.txt" && echo same || diff "$W/se-expected.txt" "$W/se-got.txt" | head -3 | tr '\n' '|')" "same"
    ok "over 505 cases: 237 succeed, 14 are ARITHMETIC, 239 are BOUNDS, 15 are CAPACITY" \
      "$(wc -l < "$W/se-got.txt" | tr -d ' ') $(grep -c ' status 0 ' "$W/se-got.txt") $(grep -c ' status 2 ' "$W/se-got.txt") $(grep -c ' status 3 ' "$W/se-got.txt") $(grep -c ' status 4 ' "$W/se-got.txt")" "505 237 14 239 15"
    # WHERE CORE AND CRUBY DIVERGE, recorded: CRuby's integers do not overflow,
    # so one past each i64 edge it computes a value -- or, where that value is
    # then an index, raises -- and the entry answers ARITHMETIC instead.
    "$RUBY" "$SE" divergence "$W/se-div.txt" > /dev/null 2>&1 || true
    ok "and at each ARITHMETIC case CRuby computes something else" "$(tr '\n' '|' < "$W/se-div.txt")" \
      "tex-add-past cruby result 0 changed state[0]=0,state[1]=9223372036854775808|tex-shift-past cruby result 0 changed state[0]=0,state[1]=9223372036854775808|mask-add-past cruby result 0 changed state[0]=2,state[1]=256|col-frac-past cruby result 1 changed scr[15]=255|span-offset-past cruby raises RangeError|zalloc-mul-past cruby result 9223372036854775808 changed state[1]=72057594037927937|exec-frac-past cruby result 1 changed scr[3]=255,scr[7]=255,scr[11]=255,scr[15]=255|pwall-mul-past cruby raises RangeError|pspan-mul-past cruby raises RangeError|pmask-mul-past cruby raises RangeError|cdis-lo-add-past cruby raises RangeError|dplanes-ph-mul-past cruby result 0 changed state[2]=140737488355328,state[10]=1,state[11]=1,pl_top[1]=255,pl_top[3]=255,spanstart[1]=1,cachedheight[1]=140737488355328,span[0]=1,span[1]=1,span[2]=1,span[5]=8192,span[6]=5,sc_kind[0]=1,sc_idx[0]=0|dplanes-sky-angle-add-past cruby result 1 changed state[4]=9,state[11]=1,state[13]=1,state[14]=1,state[15]=1,state[16]=1,state[17]=65536,state[18]=6553600,state[21]=1000,sc_kind[0]=0,sc_idx[0]=0,wall[0]=1,wall[1]=1,wall[2]=1,wall[3]=65536,wall[4]=6553600,wall[5]=1000|cplanes-angle-past cruby raises NoMethodError|"
    ok "an overflowing producer keeps the selector it stored before the sum" \
      "$(grep -E '^(tex-add-past|mask-add-past) ' "$W/se-got.txt" | tr '\n' '|')" \
      "tex-add-past status 2 result untouched changed state[0]=0|mask-add-past status 2 result untouched changed none|"
    ok "a failing column keeps the pixel an earlier access wrote, and no result" \
      "$(grep '^col-prefix-past ' "$W/se-got.txt")" "col-prefix-past status 3 result untouched changed scr[11]=255"
    ok "and a selector the consumer cannot read draws nothing and answers -1" \
      "$(grep -E '^(col-selector-none|span-selector-atlas|mjob-selector-atlas) ' "$W/se-got.txt" | tr '\n' '|')" \
      "col-selector-none status 0 result -1 changed none|span-selector-atlas status 0 result -1 changed none|mjob-selector-atlas status 0 result -1 changed none|"

    # AddressSanitizer: probed by building AND running, as buffers.sh does.
    printf 'int main(void){return 0;}\n' > "$W/asanprobe.c"
    if ! "$CC_BIN" -fsanitize=address -O1 "$W/asanprobe.c" -o "$W/asanprobe" > /dev/null 2>&1 || ! "$W/asanprobe"; then
      skipped "the sanitised edge cases" "the compiler's address sanitizer does not build and run a probe" "a toolchain with AddressSanitizer runtime"
    else
      mkdir -p "$W/ska/unit"
      cp "$W/sk/unit/"* "$W/ska/unit/"; cp "$SRCFIX/manifest.tsv" "$W/ska/manifest.tsv"
      rc=0; dc_entries "$W/ska" "$W/ska/unit" -fsanitize=address || rc=$?
      ok "the entries build under AddressSanitizer" "$rc" 0
      "$CC_BIN" -std=c11 -Wall -Wextra -Werror -O1 -fsanitize=address -I"$W/ska" "$SRCFIX/edges.c" "$W/ska"/*.o \
        -o "$W/se-asan" > "$W/se-asan-cc.err" 2>&1 || true
      rc=0; "$W/se-asan" < "$W/se-cases.txt" > "$W/se-asan.txt" 2> "$W/se-asan.err" || rc=$?
      ok "under AddressSanitizer: the same 455 lines, no report, exit 0" \
        "$(cmp -s "$W/se-got.txt" "$W/se-asan.txt" && echo same) $(wc -c < "$W/se-asan.err" | tr -d ' ') $rc" "same 0 0"
      "$RUBY" "$SE" liar "$W/se-liar.txt"
      ASAN_SYMBOLIZER_PATH="$LLVM_BIN/llvm-symbolizer" "$W/se-asan" < "$W/se-liar.txt" > /dev/null 2> "$W/se-liar.err" || true
      ok "a count larger than the allocation is reported, as a read, from inside the compiled column" \
        "$(grep -c 'ERROR: AddressSanitizer: heap-buffer-overflow' "$W/se-liar.err") $(grep -c 'READ of size 1' "$W/se-liar.err") $(grep -cE '#0 0x[0-9a-f]+ in sp_dc_sp_col' "$W/se-liar.err")" "1 1 1"
      "$RUBY" "$SE" liar-exec "$W/se-liar-exec.txt"
      ASAN_SYMBOLIZER_PATH="$LLVM_BIN/llvm-symbolizer" "$W/se-asan" < "$W/se-liar-exec.txt" > /dev/null 2> "$W/se-liar-exec.err" || true
      ok "and a flat count larger than its allocation, from inside the compiled executor" \
        "$(grep -c 'ERROR: AddressSanitizer: heap-buffer-overflow' "$W/se-liar-exec.err") $(grep -c 'READ of size 1' "$W/se-liar-exec.err") $(grep -cE '#0 0x[0-9a-f]+ in sp_dc_sp_exec' "$W/se-liar-exec.err")" "1 1 1"
      "$RUBY" "$SE" liar-push "$W/se-liar-push.txt"
      ASAN_SYMBOLIZER_PATH="$LLVM_BIN/llvm-symbolizer" "$W/se-asan" < "$W/se-liar-push.txt" > /dev/null 2> "$W/se-liar-push.err" || true
      ok "and a wall bank count larger than its allocation, as a write, from inside the compiled push" \
        "$(grep -c 'ERROR: AddressSanitizer: heap-buffer-overflow' "$W/se-liar-push.err") $(grep -c 'WRITE of size 8' "$W/se-liar-push.err") $(grep -cE '#0 0x[0-9a-f]+ in sp_dc_sp_pwall' "$W/se-liar-push.err")" "1 1 1"
    fi

    # The column entry from a source.rb with ONE line changed.
    mkdir -p "$W/skm/unit"
    cp "$SRCFIX/src/entries.rb" "$ROOT/examples/doom/core/src/zone.rb" "$ROOT/examples/doom/core/src/executor.rb" \
      "$ROOT/examples/doom/core/src/jobs.rb" "$ROOT/examples/doom/core/src/checks.rb" \
      "$ROOT/examples/doom/core/src/planespan.rb" "$ROOT/examples/doom/core/src/planes.rb" "$ROOT/examples/doom/core/src/fixed.rb" \
      "$ROOT/examples/doom/core/src/statusbar.rb" "$ROOT/examples/doom/core/src/hud.rb" \
      "$ROOT/examples/doom/core/src/leaves.rb" "$ROOT/examples/doom/core/src/segs.rb" "$W/skm/unit/"
    "$RUBY" -e 'f, o = ARGV; s = File.read(f); a = "    k = base + ((frac >> 16) & 127)\n"
      s.scan(a).length == 1 or abort("anchor"); File.write(o, s.sub(a) { "    k = base + 1 + ((frac >> 16) & 127)\n" })' \
      "$ROOT/examples/doom/core/src/source.rb" "$W/skm/unit/source.rb"
    ok "the mutant source differs in one line" \
      "$(diff "$ROOT/examples/doom/core/src/source.rb" "$W/skm/unit/source.rb" | grep -c '^[<>]')" "2"
    printf 'fixed.rb\t%s\nsource.rb\t%s\nzone.rb\t%s\nexecutor.rb\t%s\njobs.rb\t%s\nchecks.rb\t%s\nplanespan.rb\t%s\nplanes.rb\t%s\nstatusbar.rb\t%s\nhud.rb\t%s\nleaves.rb\t%s\nsegs.rb\t%s\nentries.rb\t%s\n' \
      "$(awk -F"\t" '$1 == "fixed.rb" { print $2 }' "$SRCFIX/manifest.tsv")" \
      "$("$RUBY" -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$W/skm/unit/source.rb")" \
      "$(awk -F"\t" '$1 == "zone.rb" { print $2 }' "$SRCFIX/manifest.tsv")" \
      "$(awk -F"\t" '$1 == "executor.rb" { print $2 }' "$SRCFIX/manifest.tsv")" \
      "$(awk -F"\t" '$1 == "jobs.rb" { print $2 }' "$SRCFIX/manifest.tsv")" \
      "$(awk -F"\t" '$1 == "checks.rb" { print $2 }' "$SRCFIX/manifest.tsv")" \
      "$(awk -F"\t" '$1 == "planespan.rb" { print $2 }' "$SRCFIX/manifest.tsv")" \
      "$(awk -F"\t" '$1 == "planes.rb" { print $2 }' "$SRCFIX/manifest.tsv")" \
      "$(awk -F"\t" '$1 == "statusbar.rb" { print $2 }' "$SRCFIX/manifest.tsv")" \
      "$(awk -F"\t" '$1 == "hud.rb" { print $2 }' "$SRCFIX/manifest.tsv")" \
      "$(awk -F"\t" '$1 == "leaves.rb" { print $2 }' "$SRCFIX/manifest.tsv")" \
      "$(awk -F"\t" '$1 == "segs.rb" { print $2 }' "$SRCFIX/manifest.tsv")" \
      "$(awk -F"\t" '$1 == "entries.rb" { print $2 }' "$SRCFIX/manifest.tsv")" > "$W/skm/manifest.tsv"
    rc=0; dc_entries "$W/skm" "$W/skm/unit" || rc=$?
    ok "and its entries build" "$rc" 0
    "$CC_BIN" -std=c11 -O1 -I"$W/sk" "$SRCFIX/edges.c" "$W/skm/col.o" "$W/sk/span.o" "$W/sk/mjob.o" "$W/sk/none.o" \
      "$W/sk/tex.o" "$W/sk/mask.o" "$W/sk/flat.o" "$W/sk/zone.o" "$W/sk/zalloc.o" "$W/sk/jreset.o" "$W/sk/exec.o" \
      "$W/sk/pwall.o" "$W/sk/pspan.o" "$W/sk/pmask.o" "$W/sk/ph1.o" "$W/sk/ph3.o" \
        "$W/sk/cdis.o" "$W/sk/cspan.o" "$W/sk/cmask.o" "$W/sk/call.o" "$W/sk/dplanes.o" "$W/sk/cplanes.o" -o "$W/se-mut" > /dev/null 2>&1 || true
    "$W/se-mut" < "$W/se-cases.txt" > "$W/se-mut.txt" 2>&1 || true
    ok "a mutant column entry changes 13 edge lines, the first at the atlas's last index" \
      "$(diff "$W/se-expected.txt" "$W/se-mut.txt" | grep -c '^>') $(diff "$W/se-expected.txt" "$W/se-mut.txt" | grep -m1 '^>')" \
      "13 > col-atlas-last status 3 result untouched changed none"

    if [ ! -f "$WADFILE" ]; then
      skipped "the compiled entries in the game" "no IWAD" "WAD=/path/to/doom1.wad (tools/doom/fetch-iwad.sh gets one)"
    else
      dc_source_lib "$W/sk" "$W/libsource.so"
      "$CC_BIN" -shared -o "$W/libsource-mut.so" "$W/skm/col.o" "$W/sk/span.o" "$W/sk/mjob.o" "$W/sk/none.o" \
        "$W/sk/tex.o" "$W/sk/mask.o" "$W/sk/flat.o" "$W/sk/zone.o" "$W/sk/zalloc.o" "$W/sk/jreset.o" "$W/sk/exec.o" \
        "$W/sk/pwall.o" "$W/sk/pspan.o" "$W/sk/pmask.o" "$W/sk/ph1.o" "$W/sk/ph3.o" \
        "$W/sk/cdis.o" "$W/sk/cspan.o" "$W/sk/cmask.o" "$W/sk/call.o" "$W/sk/dplanes.o" "$W/sk/cplanes.o" \
        "$W/sk/sbdraw.o" "$W/sk/hudraw.o" \
        "$W/sk/pangle.o" "$W/sk/pdist.o" "$W/sk/sgscale.o" "$W/sk/lindex.o" "$W/sk/absang.o" "$W/sk/clipv.o" "$W/sk/segside.o" "$W/sk/fplane.o" "$W/sk/chplane.o" "$W/sk/ssclear.o" "$W/sk/crunch.o" "$W/sk/chkbbox.o" "$W/sk/vssort.o" "$W/sk/addspr.o" "$W/sk/segloop.o"
      spn() { # lib tag mode tics control
        rc=0; SOURCE_PORT_NATIVE="$1" "$RUBY" "$SP" "$WADFILE" "$3" "$4" "$5" > "$W/spn-$2-$3-$5.out" 2>&1 || rc=$?
        echo "rc=$rc" >> "$W/spn-$2-$3-$5.out"
        tr '\n' '|' < "$W/spn-$2-$3-$5.out"
      }
      DF="first producer-disagree none|first unreadable-selector none|first pixel-mismatch none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|first native-status none"
      QF="first job-disagree none|first unreadable-selector none|first pixel-mismatch none|first reset-disagree none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|first native-status none"
      ok "compiled, direct: every call status 0, the original's converted choice and pixels at every site" \
        "$(spn "$W/libsource.so" c direct 600 none)" \
        "$PRE6|$D600|native calls col=352285,flat=3226,mask=168760,none=2,span=94425,tex=222093,zone=30904|faults producer-disagree 0 unreadable-selector 0 pixel-mismatch 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0 native-status 0|$DF|rc=0|"
      ok "compiled, queued: every job, and the executor's pixels" \
        "$(spn "$W/libsource.so" c queued 600 none)" \
        "$PRE6|$Q600|native calls col=218948,flat=3226,jreset=600,mask=168760,mjob=133337,none=2,span=94425,tex=222093,zalloc=30904,zone=30904|faults job-disagree 0 unreadable-selector 0 pixel-mismatch 0 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0 native-status 0|$QF|rc=0|"
      ok "compiled, no sky producer: every sky column faults" \
        "$(spn "$W/libsource.so" c direct 600 no-sky)" \
        "$PRE5|$D600|native calls col=352285,flat=3226,mask=168760,none=2,span=94425,tex=220797,zone=30904|faults producer-disagree 1296 unreadable-selector 0 pixel-mismatch 1296 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0 native-status 0|first producer-disagree sky tic 572 x 106|first unreadable-selector none|first pixel-mismatch sky tic 572 x 106|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|first native-status none|rc=0|"
      ok "compiled, RES_ZONE read from the IWAD bytes: the zone jobs' pixels differ" \
        "$(spn "$W/libsource.so" c queued 200 queued-wrong-store)" \
        "$PRE6|$Q200|$REM|native calls col=80513,flat=1321,jreset=200,mask=37907,mjob=37586,none=2,span=33540,tex=82353,zalloc=8239,zone=8239|faults job-disagree 0 unreadable-selector 0 pixel-mismatch 8223 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0 native-status 0|first job-disagree none|first unreadable-selector none|first pixel-mismatch masked frame 0 masked job 12 x 96|first reset-disagree none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|first native-status none|rc=0|"
      ok "the mutant column entry in the game, direct" \
        "$(spn "$W/libsource-mut.so" m direct 200 none)" \
        "$PRE6|$D200|$REM|native calls col=118099,flat=1321,mask=37907,none=2,span=33540,tex=82353,zone=8239|faults producer-disagree 0 unreadable-selector 0 pixel-mismatch 110538 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0 native-status 0|first producer-disagree none|first unreadable-selector none|first pixel-mismatch wall tic 0 x 261|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|first native-status none|rc=0|"
      ok "and queued" \
        "$(spn "$W/libsource-mut.so" m queued 200 none)" \
        "$PRE6|$Q200|$REM|native calls col=80513,flat=1321,jreset=200,mask=37907,mjob=37586,none=2,span=33540,tex=82353,zalloc=8239,zone=8239|faults job-disagree 0 unreadable-selector 0 pixel-mismatch 77342 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0 native-status 0|first job-disagree none|first unreadable-selector none|first pixel-mismatch wall frame 0 wall job 0 x 261|first reset-disagree none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|first native-status none|rc=0|"

      section "the compiled source entries over the resident layout"
      # THE REAL SESSION, not the lane's own buffers. DEMO1 plays E1M5, and a
      # different map is a different catalog (examples/doom/core/README.md), so
      # the counts are measured for it, the schema is emitted again from this
      # run's audit with that catalog -- and must come out as the committed
      # state.tsv and access.tsv, only the prepared lengths differing -- and the
      # layout is generated from it: buffers.tsv, slots.tsv, registry.h.
      dc_session_catalog "$W/e5" "$WADFILE"
      ok "DEMO1's map is measured" "$(cat "$W/e5/map.txt")" "E1M5"
      dc_session_schema "$W/e5" "$W/audit"
      ok "the schema emitted for it is the committed one" \
        "$(cmp -s "$W/e5/state.tsv" "$ROOT/examples/doom/core/state.tsv" && echo state) $(cmp -s "$W/e5/access.tsv" "$ROOT/examples/doom/core/access.tsv" && echo access)" "state access"
      rc=0; dc_session_layout "$W/e5" || rc=$?
      ok "and its layout generates" "$rc" 0

      # Every parameter against the field it is handed (source-registry.rb).
      SR="$ROOT/tests/doom-core/source-registry.rb"
      ok "each entry parameter is a resident field with its element, count, slot and render access" \
        "$("$RUBY" "$SR" "$SRCFIX/fields.tsv" "$SRCFIX" "$W/e5/gen" "$ROOT/examples/doom/core/access.tsv" 2>&1)" \
        "fields 445 rows, 39 contexts, 235 fields (83 slots): ok"
      srmut() { # name sed-expression -- one row of fields.tsv changed; prints the diff size and the refusals
        sed "$2" "$SRCFIX/fields.tsv" > "$W/e5/fields-$1.tsv"
        printf '%s|' "$(diff "$SRCFIX/fields.tsv" "$W/e5/fields-$1.tsv" | grep -c '^[<>]')"
        "$RUBY" "$SR" "$W/e5/fields-$1.tsv" "$SRCFIX" "$W/e5/gen" "$ROOT/examples/doom/core/access.tsv" 2>&1 | tr '\n' '|'
      }
      ok "a u8 parameter handed an i64 field is refused" \
        "$(srmut element "s/^direct-column${TAB}col${TAB}atlas${TAB}textures_texdata${TAB}-\$/direct-column${TAB}col${TAB}atlas${TAB}textures_tex_atlas_base${TAB}-/")" \
        "2|refused direct-column col.atlas -> textures_tex_atlas_base: textures_tex_atlas_base is i64, the contract says u8|"
      ok "a written parameter handed a field the render entry only reads" \
        "$(srmut mode "s/^direct-column${TAB}col${TAB}scr${TAB}renderer_screen${TAB}-\$/direct-column${TAB}col${TAB}scr${TAB}job_executor_atlas${TAB}-/")" \
        "2|refused direct-column col.scr -> job_executor_atlas: the contract writes scr and doom_core_render has job_executor_atlas as in|"
      ok "a parameter left out" "$(srmut missing "/^direct-span${TAB}span${TAB}flat${TAB}/d")" "1|refused direct-span span: flat not listed|"
      ok "one cell passed as two index parameters" \
        "$(srmut twice "s/^direct-column${TAB}col${TAB}i_base${TAB}renderer_dc_srcbase${TAB}in\$/direct-column${TAB}col${TAB}i_base${TAB}renderer_dc_srcres${TAB}in/")" \
        "2|refused direct-column col: renderer_dc_srcres passed as two index parameters|"
      ok "a field the layout does not have" \
        "$(srmut unknown "s/^queued-masked${TAB}mjob${TAB}wad${TAB}job_executor_waddata${TAB}-\$/queued-masked${TAB}mjob${TAB}wad${TAB}job_executor_wad${TAB}-/")" \
        "2|refused queued-masked mjob.wad -> job_executor_wad: job_executor_wad is not an allocation|"
      ok "a job record field outside a queued context" \
        "$(srmut jobdirect "s/^direct-span${TAB}span${TAB}i_res${TAB}renderer_ds_srcres${TAB}in\$/direct-span${TAB}span${TAB}i_res${TAB}job:RES_FLAT${TAB}in/")" \
        "2|refused direct-span span.i_res -> job:RES_FLAT: a job record field outside a queued context|"
      mkdir -p "$W/e5/shifted"
      cp "$W/e5/gen/buffers.tsv" "$W/e5/gen/slots.tsv" "$W/e5/shifted/"
      sed 's/^\(#define SPINEL_DOOM_SLOT_RENDERER_DC_SRCBASE \)\([0-9]*\)$/\1X\2/' "$W/e5/gen/registry.h" \
        | awk '/^#define SPINEL_DOOM_SLOT_RENDERER_DC_SRCBASE X/ { n = substr($3, 2) + 1; print $1 " " $2 " " n; next } { print }' \
        > "$W/e5/shifted/registry.h"
      ok "and a registry.h whose column-base slot moved by one" \
        "$(diff "$W/e5/gen/registry.h" "$W/e5/shifted/registry.h" | grep -c '^[<>]')|$("$RUBY" "$SR" "$SRCFIX/fields.tsv" "$SRCFIX" "$W/e5/shifted" "$ROOT/examples/doom/core/access.tsv" 2>&1 | head -1 | sed 's/ at [0-9]*, slots.tsv at [0-9]*$//')" \
        "2|refused direct-column col.i_base -> renderer_dc_srcbase: registry.h puts renderer_dc_srcbase"

      # The entries in the game again, now over the session: Full prepares every
      # prepared field from the objects it built, a Session opens over the
      # generated layout, and each parameter is the field fields.tsv names --
      # the selector cells views of ONE core_state at their registry slots.
      sps() { # tag mode tics fields
        rc=0; SOURCE_PORT_NATIVE="$W/libsource.so" SOURCE_PORT_SESSION="$W/e5/gen" SOURCE_PORT_FIELDS="$4" \
          "$RUBY" "$SP" "$WADFILE" "$2" "$3" none > "$W/sps-$1-$2.out" 2>&1 || rc=$?
        echo "rc=$rc" >> "$W/sps-$1-$2.out"
        tr '\n' '|' < "$W/sps-$1-$2.out"
      }
      SPRE="session fields 75 pre-tick renderer_dc_srcres=-1 renderer_dc_srcbase=0 renderer_ds_srcres=-1 renderer_ds_srcbase=0"
      ok "over the session, direct: every call status 0 and every selector in its registry slot at every column" \
        "$(sps real direct 600 "$SRCFIX/fields.tsv")" \
        "$PRE6|$D600|native calls col=352285,flat=3226,mask=168760,none=2,span=94425,tex=222093,zone=30904|faults producer-disagree 0 unreadable-selector 0 pixel-mismatch 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0 native-status 0 slot-disagree 0|$DF|first slot-disagree none|$SPRE|session selector slots hold the original's converted choice at the end yes|session other core_state slots changed 0|session read-only fields changed 0 of 41|rc=0|"
      ok "over the session, queued: and at every job" \
        "$(sps real queued 600 "$SRCFIX/fields.tsv")" \
        "$PRE6|$Q600|native calls col=218948,flat=3226,jreset=600,mask=168760,mjob=133337,none=2,span=94425,tex=222093,zalloc=30904,zone=30904|faults job-disagree 0 unreadable-selector 0 pixel-mismatch 0 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0 native-status 0 slot-disagree 0|$QF|first slot-disagree none|$SPRE|session other core_state slots changed 0|session read-only fields changed 0 of 41|rc=0|"
      # THE CONTROL: a field map that hands the column base the neighbouring
      # render slot renderer_dc_colormap. It passes source-registry.rb -- that
      # slot is a real i64 slot the render entry writes -- and the pixels still
      # agree, so only the per-call slot check can see it.
      sed "s/^\(direct-column${TAB}col${TAB}i_base${TAB}\)renderer_dc_srcbase\(${TAB}in\)\$/\1renderer_dc_colormap\2/; s/^\(produce-column${TAB}[a-z]*${TAB}i_base${TAB}\)renderer_dc_srcbase\(${TAB}inout\)\$/\1renderer_dc_colormap\2/" \
        "$SRCFIX/fields.tsv" > "$W/e5/fields-wrongslot.tsv"
      ok "a map with the column base in another slot changes four rows and passes the static check" \
        "$(diff "$SRCFIX/fields.tsv" "$W/e5/fields-wrongslot.tsv" | grep -c '^[<>]')|$("$RUBY" "$SR" "$W/e5/fields-wrongslot.tsv" "$SRCFIX" "$W/e5/gen" "$ROOT/examples/doom/core/access.tsv" 2>&1)" \
        "8|fields 445 rows, 39 contexts, 235 fields (83 slots): ok"
      ok "and is caught at the first column, direct" \
        "$(sps wrong direct 60 "$W/e5/fields-wrongslot.tsv" | tr '|' '\n' | grep -E '^(faults|first slot-disagree)' | tr '\n' '|')" \
        "faults producer-disagree 0 unreadable-selector 0 pixel-mismatch 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0 native-status 0 slot-disagree 36389|first slot-disagree wall tic 0 x 261 slots 0 0|"
      ok "and at the first job, queued" \
        "$(sps wrong queued 60 "$W/e5/fields-wrongslot.tsv" | tr '|' '\n' | grep -E '^(faults|first slot-disagree|session other)' | tr '\n' '|')" \
        "faults job-disagree 0 unreadable-selector 0 pixel-mismatch 0 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0 native-status 0 slot-disagree 37703|first slot-disagree wall frame 0 wall job 0 slots 0 0|session other core_state slots changed 1 first renderer_dc_colormap|"
      # THE COMPILED RING PRODUCER OVER THE SESSION writes jobs_zonebuf, the one
      # ring the executor's view reads; writing a second ring instead is seen only
      # through that view.
      spz() { rc=0; SOURCE_PORT_NATIVE="$W/libsource.so" SOURCE_PORT_SESSION="$W/e5/gen" \
        "$RUBY" "$SP" "$WADFILE" queued 60 zone-separate-ring > "$W/spz.out" 2>&1 || rc=$?; echo "rc=$rc" >> "$W/spz.out"
        grep -E '^(masked|native calls|faults|first pixel|first zone-disagree|rc=)' "$W/spz.out" | tr '\n' '|'; }
      ok "over the session, a compiled ring producer writing a second ring leaves the executor's view stale" "$(spz)" "masked remaining wad-min 136 zone-max 123 zone-windows 660|native calls col=32851,flat=346,jreset=60,mask=4198,mjob=4198,none=2,span=9837,tex=33565,zalloc=660,zone=660|faults job-disagree 0 unreadable-selector 0 pixel-mismatch 660 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0 native-status 0 slot-disagree 0|first pixel-mismatch masked frame 0 masked job 12 x 96|first zone-disagree none|rc=0|"

      section "the source entries through the 0007 adapter registry"
      # THE CALLER HOLDS IDS, NOT POINTERS. spinel-core-adapter generates each
      # contract's adapter and the one registry they share; the lane links them
      # with the kernel objects and runs the game with every resident field as
      # registry storage and every call an `invoke` over ids
      # (tests/doom-core/source-adapter.rb) -- core_state one id, handed over once
      # with the indices of its cells.
      ADAPTER_BIN="${ADAPTER:-$ROOT/tools/mlir/native/build/bin/spinel-core-adapter}"
      rc=0; dc_adapter_generate "$W/sk" "$W/ad" || rc=$?
      ok "every entry's adapter generates" "$rc" 0
      ok "and all of them share one registry, the same file each time" \
        "$(for e in $SENTRIES; do cmp -s "$W/ad/registry-col.c" "$W/ad/registry-$e.c" && printf 's' || printf 'D'; done)" "sssssssssssssssssssssssssssssssssssssss"
      rc=0; dc_adapter_link "$W/sk" "$W/ad" "$W/libadapter.so" || rc=$?
      ok "they compile and link with the kernel objects" "$rc" 0
      # A CALLER OF THE ADAPTER NEEDS THE ADAPTER. The same caller linked with the
      # kernel objects alone must fail to link, naming the adapter's symbols --
      # otherwise the lane could be reaching the kernels some other way.
      printf '#include "spinel_adapter_registry.h"\n#include "spinel_adapter_dc_sp_col.h"\nint main(void) { if (spinel_adapter_registry_startup()) return 1; return spinel_adapter_dc_sp_col_invoke(1, 2, 3, 4, 5, 6, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7) == 0; }\n' > "$W/ad/caller.c"
      "$CC_BIN" -std=c11 -I"$W/ad" "$W/ad/caller.c" "$W/ad/obj"/*.o "$W/sk"/*.o -lpthread -o "$W/ad/caller" > "$W/ad/with.err" 2>&1 && echo linked > "$W/ad/with.rc" || echo failed > "$W/ad/with.rc"
      "$CC_BIN" -std=c11 -I"$W/ad" "$W/ad/caller.c" "$W/sk"/*.o -o "$W/ad/caller-bare" > "$W/ad/bare.err" 2>&1 && echo linked > "$W/ad/bare.rc" || echo failed > "$W/ad/bare.rc"
      ok "a caller links with the adapter, and without it fails naming the adapter's symbols" \
        "$(cat "$W/ad/with.rc") $(cat "$W/ad/bare.rc") $(grep -c 'spinel_adapter_dc_sp_col_invoke' "$W/ad/bare.err" | tr -d ' ') $(grep -c 'spinel_adapter_registry_startup' "$W/ad/bare.err" | tr -d ' ')" \
        "linked failed 1 1"
      spa() { # tag mode tics control
        rc=0; SOURCE_PORT_NATIVE="$W/libadapter.so" SOURCE_PORT_SESSION="$W/e5/gen" SOURCE_PORT_ADAPTER="$W/libadapter.so" \
          "$RUBY" "$SP" "$WADFILE" "$2" "$3" "$4" > "$W/spa-$1-$2.out" 2>&1 || rc=$?
        echo "rc=$rc" >> "$W/spa-$1-$2.out"
        tr '\n' '|' < "$W/spa-$1-$2.out"
      }
      ok "through the adapter, direct: every call an invoke over ids, status 0, the original's choice and pixels" \
        "$(spa real direct 600 none)" "producers added 8 markers 3 pre-tick port -1 0 -1 0 original -1 0 -1 0|demo DEMO1 map E1M5 tics 5026|tics 600 columns 352285 spans 94425|sites masked=133337@tic0,sky=1296@tic572,wall=217652@tic0|masked remaining wad-min 128 zone-max 127 zone-windows 30904|native calls col=352285,flat=3226,mask=168760,none=2,span=94425,tex=222093,zone=30904|faults producer-disagree 0 unreadable-selector 0 pixel-mismatch 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0 native-status 0 slot-disagree 0|first producer-disagree none|first unreadable-selector none|first pixel-mismatch none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|first native-status none|first slot-disagree none|session fields 10 pre-tick renderer_dc_srcres=-1 renderer_dc_srcbase=0 renderer_ds_srcres=-1 renderer_ds_srcbase=0|session selector slots hold the original's converted choice at the end yes|session other core_state slots changed 0|session read-only fields changed 0 of 4 read back, of 8|adapter a refused column answers 3; its screen then answers a load -1 and a step 1; its read-only colormap and state still load yes 0|adapter core_state passed as both the reset's state and its table answers 1|adapter ids allocated 19, released once 19, every id then refuses a second release|rc=0|"
      ok "through the adapter, queued: the ring written and read through one id, the reset through the registry" \
        "$(spa real queued 600 none)" "producers added 8 markers 3 pre-tick port -1 0 -1 0 original -1 0 -1 0|demo DEMO1 map E1M5 tics 5026|frames 600 wall-jobs 222093 span-jobs 94425 masked-jobs 133337 zone-jobs 28141 resets 600 of 31+1 cells|sites masked=133337@frame0,sky=1296@frame572,wall=220797@frame0|masked remaining wad-min 128 zone-max 127 zone-windows 30904|native calls col=218948,flat=3226,jreset=600,mask=168760,mjob=133337,none=2,span=94425,tex=222093,zalloc=30904,zone=30904|faults job-disagree 0 unreadable-selector 0 pixel-mismatch 0 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0 native-status 0 slot-disagree 0|first job-disagree none|first unreadable-selector none|first pixel-mismatch none|first reset-disagree none|first zone-disagree none|first zone-slot-disagree none|first zone-capacity none|first native-status none|first slot-disagree none|session fields 11 pre-tick renderer_dc_srcres=-1 renderer_dc_srcbase=0 renderer_ds_srcres=-1 renderer_ds_srcbase=0|session other core_state slots changed 0|session read-only fields changed 0 of 5 read back, of 9|adapter a refused column answers 3; its screen then answers a load -1 and a step 1; its read-only colormap and state still load yes 0|adapter core_state passed as both the reset's state and its table answers 1|adapter ids allocated 20, released once 20, every id then refuses a second release|rc=0|"
      ok "through the adapter, a ring producer writing a second ring leaves the executor's view stale" \
        "$(spa sep queued 60 zone-separate-ring | tr '|' '\n' | grep -E '^(native calls|faults|first pixel|adapter|rc=)' | tr '\n' '|')" "native calls col=32851,flat=346,jreset=60,mask=4198,mjob=4198,none=2,span=9837,tex=33565,zalloc=660,zone=660|faults job-disagree 0 unreadable-selector 0 pixel-mismatch 660 reset-disagree 0 zone-disagree 0 zone-slot-disagree 0 zone-capacity 0 native-status 0 slot-disagree 0|first pixel-mismatch masked frame 0 masked job 12 x 96|adapter a refused column answers 3; its screen then answers a load -1 and a step 1; its read-only colormap and state still load yes 0|adapter core_state passed as both the reset's state and its table answers 1|adapter ids allocated 21, released once 21, every id then refuses a second release|rc=0|"
      # EVERY ID IS RELEASED, the lane's own helper cells too: after the releases,
      # every id from 1 to the highest the registry handed out must refuse a second
      # release. The control allocates the result cell without tracking it.
      ok "an id allocated and never released is found by id, and fails the run" \
        "$(export SOURCE_PORT_ADAPTER_UNTRACKED=result; spa leak queued 60 none | tr "|" "\n" | grep -E "^(adapter ids|rc=)" | tr "\n" "|")" \
        "adapter ids allocated 20, released once 19, a second release is accepted by 2, never released|rc=1|"
      # A STEP THE ADAPTER REFUSES ENDS THE SESSION. With a reset table missing the
      # ring's counter the ring fills, and the first refused invoke -- CAPACITY, by
      # name -- stops the game: nothing more is invoked, nothing is read back from
      # the poisoned storage, every id is released once, and the run fails.
      ok "through the adapter, the first refused step ends the session, reads nothing back and releases every id" \
        "$(spa fail queued 200 reset-drop-nzone | tr '|' '\n' | grep -E '^(faults|first native-status|adapter|session|rc=)' | tr '\n' '|')" \
        "faults job-disagree 0 unreadable-selector 0 pixel-mismatch 2921 reset-disagree 130 zone-disagree 0 zone-slot-disagree 3067 zone-capacity 0 native-status 1 slot-disagree 0|first native-status zalloc CAPACITY (4) masked tic 130 frame 130|adapter session failed at zalloc CAPACITY (4) masked tic 130 frame 130: no further invoke, no poisoned buffer read|adapter ids allocated 20, released once 20, every id then refuses a second release|rc=1|"
    fi

  fi
fi

else
  section "the source port beside the original (retired)"
  stage1_retired "the source selector lanes and the compiled source entries beside the original"
fi

tick_times
echo "tick: $((pass + fail)) checked, $pass pass, $fail fail, $skip lane(s) skipped$skips"
if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -ne 0 ]; then
  echo "tick: REQUIRE_ALL=1, and $skip lane(s) did not run" >&2
  exit 1
fi
echo "tick: every definition of the three entries is in a final ledger state; migrated means named and present, and step-diff.rb and render-diff.rb are what compare them" >&2
[ "$fail" -eq 0 ] || exit 1
