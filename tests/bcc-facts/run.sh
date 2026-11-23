#!/bin/sh
# tests/bcc-facts/run.sh -- tools/bcc-facts/emit-facts.rb: the 28 bcc tools'
# spinel_facts v2 modules from this repository's Spinel, and its contract check.
#
#   sh tests/bcc-facts/run.sh DIR
#
# DIR is a fresh directory outside the checkout. It checks:
#   1. all 35 tools give a module that keeps the contract (and, with CONSUMER
#      set to spinel-mlir's consumer, that it accepts each one);
#   2. the same tool twice gives the same bytes;
#   3. the check refuses, each by name, three modules planted from a good one:
#      an analysis-only integers.enum_copy on a pristine node, a root list that
#      is not the one requested, and version 1;
#   4. with CONSUMER, the seam check (E075) passes cachestat's outputs and
#      refuses two copies planted from them: a byte added to the maps, and a
#      manifest that records rc 1;
#   5. under LC_ALL=C, the check reads a module that holds non-ASCII text:
#      cachestat's, with a UTF-8 comment line planted after its header;
#   6. with CONSUMER and EBPF_OPT (bpf-mlir's ebpf-opt), the acceptance
#      oracle's generic comparison (tests/bcc-facts/acceptance.rb
#      --generic-check), on the consumer's own cachestat.mlir only: equal to
#      itself and to its generic text with locations, and unequal to copies
#      planted with one Ruby location moved by a line and one constant changed.
# Nothing is compared with another implementation's output.
#
# Requires: vendor/spinel built (docs/building.md), or SPINEL.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
[ $# -eq 1 ] || { echo "usage: sh tests/bcc-facts/run.sh DIR" >&2; exit 2; }
WORK=$1
case $WORK in "$ROOT"|"$ROOT"/*) echo "run: DIR must be outside the checkout" >&2; exit 2 ;; esac
[ ! -e "$WORK" ] || [ -z "$(ls -A "$WORK" 2>/dev/null)" ] || { echo "run: DIR $WORK is not empty" >&2; exit 2; }
mkdir -p "$WORK" || exit 2
E="$ROOT/tools/bcc-facts/emit-facts.rb"
set -- --spinel "${SPINEL:-$ROOT/vendor/spinel/bin/spinel}"
[ -n "${CONSUMER:-}" ] && set -- "$@" --consumer "$CONSUMER"
n=0; bad=0
ok() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "  pass $1"; else echo "  FAIL $1: want $3, got $2"; bad=$((bad + 1)); fi; }

echo "bcc-facts: 1. the 35 tools"
ruby "$E" "$@" "$WORK/all" > "$WORK/all.log" 2>&1
ok "exit 0" "$?" 0
ok "35 of 35 pass" "$(tail -1 "$WORK/all.log" | sed 's/^emit-facts: \([0-9]* of [0-9]*\) pass.*/\1/')" "35 of 35"
ok "35 rows, each contract ok" "$(awk -F'\t' '!/^#/ && $6 == "ok"' "$WORK/all/summary.tsv" 2>/dev/null | wc -l | tr -d ' ')" 35
ok "the typing probe asked for tcpretrans only" "$(awk -F'\t' '!/^#/ && $8 == "yes" { print $1 }' "$WORK/all/summary.tsv" 2>/dev/null)" tcpretrans

echo "bcc-facts: 2. the same tool twice"
ruby "$E" "$@" "$WORK/again" cachestat > "$WORK/again.log" 2>&1
ok "the second run exits 0" "$?" 0
a=$(sha256sum < "$WORK/all/cachestat/facts.mlir" | cut -d' ' -f1)
b=$(sha256sum < "$WORK/again/cachestat/facts.mlir" 2>/dev/null | cut -d' ' -f1)
ok "cachestat's module is the same bytes" "$b" "$a"

echo "bcc-facts: 3. planted modules"
F="$WORK/all/cachestat/facts.mlir"
R="on_access:obj_BPF::KprobeCtx on_miss:obj_BPF::KprobeCtx on_dirty:obj_BPF::KprobeCtx"
# shellcheck disable=SC2086
ruby "$E" --check "$F" $R > "$WORK/good.out"
ok "the good module passes the check" "$?" 0
# an analysis-only key on the first pristine node that has integers
ruby -e 's = File.read(ARGV[0]); i = s.index(%(integers = {"node_line")) or abort("no node"); s.insert(i + 12, %("enum_copy" = "1", )); File.write(ARGV[1], s)' "$F" "$WORK/pristine.mlir" || exit 2
# shellcheck disable=SC2086
ruby "$E" --check "$WORK/pristine.mlir" $R > "$WORK/pristine.out"
ok "a pristine enum_copy is refused" "$?" 1
ok "  by name" "$(grep -c 'carries the analysis-only integers.enum_copy' "$WORK/pristine.out")" 1
ruby "$E" --check "$F" on_access:obj_BPF::KprobeCtx > "$WORK/roots.out"
ok "a different root list is refused" "$?" 1
ok "  by name" "$(grep -c 'analysis_roots are' "$WORK/roots.out")" 1
sed '1s/spinel_facts.version = 2 : i64/spinel_facts.version = 1 : i64/' "$F" > "$WORK/v1.mlir"
# shellcheck disable=SC2086
ruby "$E" --check "$WORK/v1.mlir" $R > "$WORK/v1.out"
ok "version 1 is refused" "$?" 1
ok "  by name" "$(grep -c 'spinel_facts.version is not 2' "$WORK/v1.out")" 1

if [ -n "${CONSUMER:-}" ]; then
  echo "bcc-facts: 4. the consumer's seam outputs (CONSUMER set)"
  ok "cachestat's E and I pass the seam check" "$(ruby "$E" --check-seam cachestat "$WORK/all/cachestat/E" "$WORK/all/cachestat/I" "$F" > /dev/null; echo $?)" 0
  cp -r "$WORK/all/cachestat" "$WORK/seam-byte"
  printf ' ' >> "$WORK/seam-byte/E/cachestat.maps.json"
  ruby "$E" --check-seam cachestat "$WORK/seam-byte/E" "$WORK/seam-byte/I" "$F" > "$WORK/seam-byte.out"
  ok "one byte added to the maps is refused" "$?" 1
  ok "  by name" "$(grep -c "the manifest's maps sha256 is not the file's" "$WORK/seam-byte.out")" 1
  cp -r "$WORK/all/cachestat" "$WORK/seam-rc"
  sed 's/"rc": 0/"rc": 1/' "$WORK/all/cachestat/I/cachestat.inspect-manifest.json" > "$WORK/seam-rc/I/cachestat.inspect-manifest.json"
  ruby "$E" --check-seam cachestat "$WORK/seam-rc/E" "$WORK/seam-rc/I" "$F" > "$WORK/seam-rc.out"
  ok "a manifest that records rc 1 is refused" "$?" 1
  ok "  by name" "$(grep -c "the manifest's result is" "$WORK/seam-rc.out")" 1
fi

echo "bcc-facts: 5. non-ASCII text under LC_ALL=C"
ruby -e 'l = File.binread(ARGV[0]).lines; l.insert(1, "// planted: caf\u00e9\n".b); File.binwrite(ARGV[1], l.join)' "$F" "$WORK/utf8.mlir" || exit 2
# shellcheck disable=SC2086
LC_ALL=C ruby "$E" --check "$WORK/utf8.mlir" $R > "$WORK/utf8.out" 2>&1
ok "the module passes the check" "$?" 0
ok "  and nothing raised" "$(grep -c 'invalid byte sequence' "$WORK/utf8.out")" 0

if [ -n "${CONSUMER:-}" ] && [ -n "${EBPF_OPT:-}" ]; then
  echo "bcc-facts: 6. the acceptance's generic comparison (CONSUMER and EBPF_OPT set)"
  A="$ROOT/tests/bcc-facts/acceptance.rb"
  M="$WORK/all/cachestat/E/cachestat.mlir"
  "$EBPF_OPT" --mlir-print-op-generic --mlir-print-debuginfo --mlir-print-local-scope "$M" > "$WORK/g-text.mlir" || exit 2
  ruby -e 's = File.read(ARGV[0]); t = s.sub(/loc\("cachestat\.rb":(\d+):(\d+)\)/) { %(loc("cachestat.rb":1:)) }; abort if t == s; File.write(ARGV[1], t)' "$M" "$WORK/g-loc.mlir" || exit 2
  ruby -e 's = File.read(ARGV[0]); t = s.sub(/arith\.constant (\d+) : i64/) { %(arith.constant 1 : i64) }; abort if t == s; File.write(ARGV[1], t)' "$M" "$WORK/g-const.mlir" || exit 2
  ok "the module equals itself" "$(ruby "$A" --generic-check "$EBPF_OPT" "$M" "$M"; echo $?)" 0
  ok "  and its generic text with locations" "$(ruby "$A" --generic-check "$EBPF_OPT" "$M" "$WORK/g-text.mlir"; echo $?)" 0
  ok "a Ruby location moved by a line is unequal" "$(ruby "$A" --generic-check "$EBPF_OPT" "$M" "$WORK/g-loc.mlir"; echo $?)" 1
  ok "a changed constant is unequal" "$(ruby "$A" --generic-check "$EBPF_OPT" "$M" "$WORK/g-const.mlir"; echo $?)" 1
fi

echo "bcc-facts: $n checked, $((n - bad)) pass, $bad fail"
[ "$bad" -eq 0 ]
