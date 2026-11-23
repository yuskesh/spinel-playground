#!/usr/bin/env bash
#
# tests/spinel-vi/run.sh — examples/spinel-vi, end to end.
#
#   bash tests/spinel-vi/run.sh
#
# Builds the editor offline from the vendored termbox2 / libgrapheme snapshots
# and runs its checks:
#
#   - the example's own gates: test/run-gates.sh (the Phase 0 ABI probe, real
#     PTY included), test/run-editor-gates.sh and test/run-e103-gates.sh;
#   - the Spinel legs of spinel-llvm's E101 and E103-E106 gates, which lived in
#     that repository's experiment archive: the piece-table fixtures, the
#     command fixture, the preflight, fake-terminal screen digests for search
#     and Unicode, the Unicode display policy, and the product entry point.
#
# Every expectation is a file of the example's (test/*.expected, *.sha256) or a
# literal here. Not run, because they are oracles: the same fixtures under
# CRuby, test/core_oracle.rb, and test/core_flat_oracle.rb against
# test/core_trace_spinel.rb (a CRuby-built flat String reference).
#
# The real-PTY legs need perl and script(1). Exit 0 on success, 1 on the first
# failure (the example's gates stop at their first failure too).
set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
APP="$REPO/examples/spinel-vi"
SPINEL="$REPO/vendor/spinel/bin/spinel"
BUILD="$APP/build/tests"
rm -rf "$BUILD"
mkdir -p "$BUILD"

deadline() { perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!\n"' "$@"; }
pass() { printf 'PASS\t%s\t%s\n' "$1" "$2"; }
[ -x "$SPINEL" ] || { echo "---- spinel-vi: SKIP (build vendor/spinel first)"; exit 2; }

echo "== the example's own gates"
deadline 120 bash "$APP/test/run-gates.sh"
deadline 120 bash "$APP/test/run-editor-gates.sh"
deadline 120 bash "$APP/test/run-e103-gates.sh"
EDITOR="$APP/build/e102-gates/editor"

echo "== piece table and commands (E101, E103)"
fixture() {  # <name> <rb> <expected>
  deadline 60 "$SPINEL" "$APP/test/$2" -o "$BUILD/$1" >/dev/null
  deadline 10 "$BUILD/$1" | diff -u "$APP/test/$3" -
}
fixture core-unit core_unit.rb core_unit.expected
pass unit 'NUL, coalesce, empty table, loud range, factory type fixture'
fixture core-piece-factory core_piece_factory.rb core_piece_factory.expected
pass piece_factory 'factory fixture'
fixture editor-commands editor_commands.rb editor_commands.expected
pass editor_commands 'command fixture'
deadline 60 "$SPINEL" "$APP/test/core_preflight.rb" -o "$BUILD/core-preflight" >/dev/null
test "$(deadline 30 "$BUILD/core-preflight")" = 'preflight bytes=65536 ops=1000 added=1000 pieces=1 valid=true'
pass preflight_64k_1k '64KiB original, 1000 insert/delete pairs, normalized to one piece'

echo "== search (E104)"
printf 'cat\nfoo\nfoo\nbbb' > "$BUILD/search.txt"
deadline 10 "$EDITOR" --fake-search-trace "$BUILD/search.txt" > "$BUILD/fake-search.out"
test "$(shasum -a 256 "$BUILD/fake-search.out" | awk '{print $1}')" = \
  "$(tr -d '\n' < "$APP/test/editor_e104_search.expected.sha256")"
grep -F $'search-final\ttext="cat\\nfoo\\nfoo\\nbbb"\tcursor=8\tmatch=8,8\tnotice="search error:' \
  "$BUILD/fake-search.out" >/dev/null
pass fake_search_screen_golden '/pattern, n, wrap, zero-length byte progress, invalid nonmutation'

echo "== Unicode (E105)"
printf 'e\314\201\343\201\202\nA\343\201\202\nA\n' > "$BUILD/unicode.txt"
deadline 10 "$EDITOR" --fake-unicode-trace "$BUILD/unicode.txt" > "$BUILD/unicode.out"
grep -F $'unicode-step\t2\tcursor=8\tline=1\tcolumn=1' "$BUILD/unicode.out" >/dev/null
grep -F $'unicode-step\t3\tcursor=13\tline=2\tcolumn=1' "$BUILD/unicode.out" >/dev/null
grep -F $'unicode-final\ttext="\\nAあ\\nA\\n"\tcursor=0\tline=0\tcolumn=0' "$BUILD/unicode.out" >/dev/null
test "$(shasum -a 256 "$BUILD/unicode.out" | awk '{print $1}')" = \
  "$(tr -d '\n' < "$APP/test/editor_e105_unicode.expected.sha256")"
pass egc_navigation_delete 'combining and wide EGCs move and delete as one; j/k keep the column'

printf '\360\237\221\215\360\237\217\275\n' > "$BUILD/skin.txt"
printf '\360\237\221\251\342\200\215\360\237\222\273\n' > "$BUILD/zwj.txt"
printf '\360\237\207\257\360\237\207\265\n' > "$BUILD/flag.txt"
for f in skin zwj flag; do
  deadline 10 "$EDITOR" "$BUILD/$f.txt" > "$BUILD/$f.out"
  grep -E '^putegc[[:space:]]+0[[:space:]]+0[[:space:]]+U\+[0-9A-F]+[[:space:]]+(2|3)[[:space:]]' "$BUILD/$f.out" >/dev/null
done
pass emoji_modifier_zwj_flag 'skin tone, ZWJ and flag pair each draw as one EGC'

printf '\302\241A\n' > "$BUILD/ambiguous.txt"
deadline 10 "$EDITOR" "$BUILD/ambiguous.txt" > "$BUILD/ambiguous.out"
grep -F $'putegc\t0\t0\tU+00A1' "$BUILD/ambiguous.out" >/dev/null
grep -F $'put\t1\t0\tU+0041' "$BUILD/ambiguous.out" >/dev/null
printf '\t\001\n' > "$BUILD/tab.txt"
deadline 10 "$EDITOR" "$BUILD/tab.txt" > "$BUILD/tab.out"
grep -F $'put\t0\t0\tU+003E' "$BUILD/tab.out" >/dev/null
grep -F $'put\t8\t0\tU+005E' "$BUILD/tab.out" >/dev/null
grep -F $'put\t9\t0\tU+0041' "$BUILD/tab.out" >/dev/null
pass ambiguous_tab_control 'ambiguous width 1, tab to the next 8-column stop, control as caret'

printf 'A\343\201\202\n' > "$BUILD/narrow.txt"
deadline 10 "$EDITOR" --fake-unicode-narrow-trace "$BUILD/narrow.txt" > "$BUILD/narrow.out"
awk 'seen { print } /^event\t2\t/ { seen=1 }' "$BUILD/narrow.out" > "$BUILD/narrow-tail.out"
grep -F $'put\t0\t0\tU+0041' "$BUILD/narrow-tail.out" >/dev/null
! grep -F 'putegc' "$BUILD/narrow-tail.out" >/dev/null
pass right_edge_wide_egc_blank 'a wide EGC that would cross the right edge is left blank'

printf '1\357\270\217\342\203\243\n' > "$BUILD/unsafe.txt"
deadline 10 "$EDITOR" "$BUILD/unsafe.txt" > "$BUILD/unsafe.out"
test "$(cat "$BUILD/unsafe.out")" = \
  'unicode-error=Unicode display width is unsafe for this EGC; ASCII-only editor'
pass unsafe_egc_refused 'a keycap is refused before the terminal is initialised'

echo "== the product entry point (E106)"
deadline 120 "$APP/build.sh" "$BUILD/spinel-vi" >/dev/null
printf 'ASCII\n' > "$BUILD/ascii.txt"
SPINEL_VI_BIN="$BUILD/spinel-vi" SPINEL_VI_BACKEND=fake \
  deadline 10 "$APP/run.sh" "$BUILD/ascii.txt" > "$BUILD/ascii.out"
! grep -F 'unicode-error=' "$BUILD/ascii.out" >/dev/null
grep -F 'shutdown' "$BUILD/ascii.out" >/dev/null
printf 'e\314\201\343\201\202\n\360\237\221\251\342\200\215\360\237\222\273\n\360\237\207\257\360\237\207\265\n' > "$BUILD/uni.txt"
SPINEL_VI_BIN="$BUILD/spinel-vi" SPINEL_VI_BACKEND=fake \
  deadline 10 "$APP/run.sh" "$BUILD/uni.txt" > "$BUILD/uni.out"
! grep -F 'unicode-error=' "$BUILD/uni.out" >/dev/null
grep -F $'putegc\t0\t0\tU+0065\t2' "$BUILD/uni.out" >/dev/null
grep -F 'U+1F469' "$BUILD/uni.out" >/dev/null
grep -F 'U+1F1EF' "$BUILD/uni.out" >/dev/null
pass product_build_and_run 'offline build from the vendored snapshots; ASCII and Unicode files open and close'

echo "---- spinel-vi: PASS"
