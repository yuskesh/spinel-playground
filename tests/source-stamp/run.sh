#!/bin/sh
# tests/source-stamp/run.sh — tools/test/source-stamp.rb, on stamps it writes here.
#
#   sh tests/source-stamp/run.sh
#
# Each case writes a stamp from this tree beside a stand-in binary in a
# scratch directory, changes one thing, and requires `check` to refuse it by
# name, or to accept the unchanged stamp:
#   * a kernel stamp written from this tree is accepted;
#   * a kernel with no stamp, a stamp with one digest changed, and a stamp
#     missing one of the tree's inputs are refused, naming the input;
#   * a reader stamp over the vendor sources of the pinned commit (taken from
#     the submodule store with git archive) is accepted, and one whose vendor
#     checkout has one edited source is refused, naming it;
#   * the lanes' helper (tools/test/source-stamp.sh) stops a lane
#     on a refused binary and lets an absent one through to the lane's own
#     refusal.
# It builds nothing and needs no kernel: the binaries are stand-ins, since the
# stamp is about the source and not the bytes.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RUBY="${RUBY:-ruby}"
TOOL="$ROOT/tools/test/source-stamp.rb"
W=$(mktemp -d "${TMPDIR:-/tmp}/source-stamp.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
TAB=$(printf '\t')
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
check() { # kind binary out
  "$RUBY" "$TOOL" check "$1" "$2" > "$3" 2>&1 && echo 0 > "$3.rc" || echo $? > "$3.rc"
}

echo "the kernel"
mkdir -p "$W/k"; echo stand-in > "$W/k/spinel-core-kernel"
"$RUBY" "$TOOL" write kernel "$W/k" > "$W/kw.out"
check kernel "$W/k/spinel-core-kernel" "$W/k.out"
ok "a stamp written from this tree is accepted" \
   "$(cat "$W/k.out.rc")|$(grep -c "built from this tree's source" "$W/k.out")" "0|1"
ok "  and it names tools/realtime/alloc_vocabulary.tsv, which the build embeds" \
   "$(grep -c "^tools/realtime/alloc_vocabulary.tsv${TAB}sha256:" "$W/k/source-stamp.tsv")" 1
ok "  and leaves the lit tests out" "$(grep -c '^tools/mlir/native/test/' "$W/k/source-stamp.tsv")" 0

mkdir -p "$W/none"; echo stand-in > "$W/none/spinel-core-kernel"
check kernel "$W/none/spinel-core-kernel" "$W/none.out"
ok "a kernel with no stamp is refused" \
   "$(cat "$W/none.out.rc")|$(grep -c 'has no source stamp beside it' "$W/none.out")" "1|1"

mkdir -p "$W/edit"; cp "$W/k/spinel-core-kernel" "$W/edit/"
sed "s|^\(tools/mlir/native/CMakeLists.txt${TAB}sha256:\).*|\10000|" "$W/k/source-stamp.tsv" > "$W/edit/source-stamp.tsv"
check kernel "$W/edit/spinel-core-kernel" "$W/edit.out"
ok "a stamp with one input's digest changed is refused, naming it" \
   "$(cmp -s "$W/k/source-stamp.tsv" "$W/edit/source-stamp.tsv" && echo same || echo edited)|$(cat "$W/edit.out.rc")|$(grep -c 'built from other source than this tree.s: 1 input(s) differ: tools/mlir/native/CMakeLists.txt;' "$W/edit.out")" \
   "edited|1|1"

mkdir -p "$W/drop"; cp "$W/k/spinel-core-kernel" "$W/drop/"
grep -v "^tools/realtime/alloc_vocabulary.tsv${TAB}" "$W/k/source-stamp.tsv" > "$W/drop/source-stamp.tsv"
check kernel "$W/drop/spinel-core-kernel" "$W/drop.out"
ok "a stamp missing one of the tree's inputs is refused, naming it" \
   "$(cat "$W/drop.out.rc")|$(grep -c 'tools/realtime/alloc_vocabulary.tsv (only in the tree)' "$W/drop.out")" "1|1"

echo "the reader"
PIN=$(cd "$ROOT" && git ls-files -s -- vendor/spinel | cut -d' ' -f2)
# The same stores the tool reads, in its order: the vendor checkout's own git
# directory (a worktree's submodule), then the shared one.
STORE=
for s in "$(git -C "$ROOT/vendor/spinel" rev-parse --absolute-git-dir 2>/dev/null)" \
         "$(cd "$ROOT" && git rev-parse --path-format=absolute --git-common-dir)/modules/vendor/spinel"; do
  [ -n "$s" ] && [ -d "$s" ] && git --git-dir="$s" cat-file -e "$PIN^{commit}" 2>/dev/null && { STORE=$s; break; }
done
[ -n "$STORE" ] || { echo "source-stamp: vendor/spinel $PIN is in no submodule store" >&2; exit 2; }
mkdir -p "$W/vendor"
git --git-dir="$STORE" archive "$PIN" src Makefile common.mk | (cd "$W/vendor" && tar -xf -)
mkdir -p "$W/r"; echo stand-in > "$W/r/spinel-typedump"
"$RUBY" "$TOOL" write reader "$W/r/spinel-typedump" --vendor "$W/vendor" > "$W/rw.out"
check reader "$W/r/spinel-typedump" "$W/r.out"
ok "a stamp over the pinned commit's vendor sources is accepted" \
   "$(cat "$W/r.out.rc")|$(grep -c "built from this tree's source" "$W/r.out")" "0|1"
ok "  and it names the vendor sources it linked" "$(grep -c "^vendor/spinel/src/.*${TAB}blob:" "$W/r/source-stamp.tsv" | sed 's/^[1-9][0-9]*$/some/')" some

printf '/* planted */\n' >> "$W/vendor/src/main.c"
mkdir -p "$W/rv"; echo stand-in > "$W/rv/spinel-typedump"
"$RUBY" "$TOOL" write reader "$W/rv/spinel-typedump" --vendor "$W/vendor" > "$W/rvw.out"
check reader "$W/rv/spinel-typedump" "$W/rv.out"
ok "a reader linked from a vendor checkout with one source edited is refused, naming it" \
   "$(cat "$W/rv.out.rc")|$(grep -c '1 input(s) differ: vendor/spinel/src/main.c;' "$W/rv.out")" "1|1"

echo "the lanes' helper"
cat > "$W/lane.sh" <<'EOF'
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$1"
echo "the lane went on"
EOF
ROOT=$ROOT sh "$W/lane.sh" "$W/edit/spinel-core-kernel" > "$W/lane-bad.out" 2>&1 && echo 0 > "$W/lane-bad.rc" || echo $? > "$W/lane-bad.rc"
ok "a refused kernel stops the lane before it is used" \
   "$(cat "$W/lane-bad.rc")|$(grep -c 'the lane went on' "$W/lane-bad.out")" "1|0"
ROOT=$ROOT sh "$W/lane.sh" "$W/k/spinel-core-kernel" > "$W/lane-good.out" 2>&1
ok "an accepted one lets it go on" "$(grep -c 'the lane went on' "$W/lane-good.out")" 1
ROOT=$ROOT sh "$W/lane.sh" "$W/absent/spinel-core-kernel" > "$W/lane-absent.out" 2>&1
ok "an absent one is left to the lane's own refusal" "$(grep -c 'the lane went on' "$W/lane-absent.out")" 1

echo "source-stamp: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ]
