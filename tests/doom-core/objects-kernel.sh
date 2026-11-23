#!/bin/sh
#
# tests/doom-core/objects-kernel.sh — reused entry objects are refused unless
# this kernel built them (tools/doom/objects-kernel.rb), without a board.
#
#   sh tests/doom-core/objects-kernel.sh [DIR]
#
# rt1186.sh (THUMB_BUILD, CORE_BUILD) and rt1186-profile.sh (LANE_DIR) reuse a
# previous run's entries; on 2026-10-21 a profile and a board run on the M7
# measured objects an older kernel had built. Checked here, on planted
# reports (no kernel is run: --kernel is any file, its sha256 the one wanted):
#
#   1. three reports naming the kernel's sha256 are accepted;
#   2. a report naming another kernel is refused, and the message names both
#      digests;
#   3. a directory missing a report is refused, naming it; a host build's
#      kernel.sha256 (dc_core_entries writes it) is read the same way;
#   4. rt1186-profile.sh stops on a lane whose objects name another kernel,
#      before it builds anything, saying so.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
W=${1:-${TMPDIR:-/tmp}/objects-kernel.$$}
RUBY=${RUBY:-ruby}
TOOL=$ROOT/tools/doom/objects-kernel.rb
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
rm -rf "$W"; mkdir -p "$W" || exit 2
sha() { "$RUBY" -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' "$1"; }
plant() { # dir sha [entries...]
  d=$1; s=$2; shift 2
  mkdir -p "$d"
  for e in "$@"; do printf '{"tools": {"kernel": {"sha256": "%s"}}}\n' "$s" > "$d/report_$e.json"; done
}
printf 'this kernel\n' > "$W/kernel"; K=$(sha "$W/kernel")
printf 'an older kernel\n' > "$W/old"; OLD=$(sha "$W/old")
ALL="doom_core_input doom_core_step doom_core_render"

echo "objects-kernel: the tool, on planted reports"
plant "$W/same" "$K" $ALL
"$RUBY" "$TOOL" --kernel "$W/kernel" "$W/same" > "$W/same.out" 2>&1
ok "three reports naming this kernel are accepted" "$?:$(grep -c "3 record(s) name the kernel $K" "$W/same.out")" "0:1"
plant "$W/older" "$K" doom_core_input doom_core_render
plant "$W/older" "$OLD" doom_core_step
"$RUBY" "$TOOL" --kernel "$W/kernel" "$W/older" > "$W/older.out" 2>&1
ok "a report naming another kernel is refused, with both digests" \
   "$?:$(grep -c "report_doom_core_step.json: built by kernel $OLD, but the kernel is $K" "$W/older.out")" "1:1"
plant "$W/missing" "$K" doom_core_input doom_core_step
"$RUBY" "$TOOL" --kernel "$W/kernel" "$W/missing" > "$W/missing.out" 2>&1
ok "a directory missing a report is refused, naming it" \
   "$?:$(grep -c 'report_doom_core_render.json: no report' "$W/missing.out")" "1:1"

mkdir -p "$W/host-same" "$W/host-old" "$W/host-none"
echo "$K" > "$W/host-same/kernel.sha256"; echo "$OLD" > "$W/host-old/kernel.sha256"
"$RUBY" "$TOOL" --kernel "$W/kernel" "$W/host-same" > "$W/host-same.out" 2>&1; a=$?
"$RUBY" "$TOOL" --kernel "$W/kernel" "$W/host-old" > "$W/host-old.out" 2>&1; b=$?
"$RUBY" "$TOOL" --kernel "$W/kernel" "$W/host-none" > "$W/host-none.out" 2>&1; c=$?
ok "a host build's kernel.sha256: this kernel's accepted, another's refused with both digests, none refused" \
   "$a:$b:$(grep -c "kernel.sha256: built by kernel $OLD, but the kernel is $K" "$W/host-old.out"):$c" "0:1:1:1"

echo "objects-kernel: rt1186-profile.sh on a lane of another kernel's objects"
plant "$W/lane/thumb/session-objects" "$OLD" $ALL
mkdir -p "$W/lane/image-DEMO1" && : > "$W/lane/image-DEMO1/image.tsv"
# rt1186-profile.sh holds its kernel to the tree's source first
# (tools/test/source-stamp.sh), so the stand-in carries a stamp written from
# this tree, as a built kernel does; and the reader is named absent, which the
# stamp check leaves to the lane, so the host's own reader cannot stop it there.
"$RUBY" "$ROOT/tools/test/source-stamp.rb" write kernel "$W" > "$W/stamp.out" 2>&1 || { cat "$W/stamp.out"; exit 2; }
KERNEL="$W/kernel" READER="$W/no-reader" CLANG=/usr/bin/false RUBY="$RUBY" sh "$ROOT/tests/doom-core/rt1186-profile.sh" "$W/lane" "$W/prof" > "$W/prof.out" 2>&1
ok "it stops before building, naming the kernel" \
   "$?:$(grep -c "rt1186-profile: $W/lane's entries were not built by this kernel" "$W/prof.out"):$([ -d "$W/prof/fw" ] && echo built || echo none)" "2:1:none"

echo "objects-kernel: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ]
