#!/bin/sh
# tests/ebpf/run.sh -- spinel-ebpf's own checks that need no privilege.
#
# spinel-ebpf is ported from spinel-ebpf 23fa4b0 into tools/ebpf (see
# tools/ebpf/README.md). This runs:
#   1. its minitest files (tools/ebpf/tests/spinel_ebpf), except the three that
#      need spinel-llvm (EXCLUDED below);
#   2. the runtime harnesses (tools/ebpf/tests/runtime) that need neither Python,
#      macOS, spinel-llvm, AMP firmware nor protoc (RUNTIME below).
# Live eBPF checks need privilege and are tests/ebpf/live.sh.
#
# Requires: vendor/spinel built (docs/building.md), LLVM clang/libbpf/libelf as
# docs/toolchains/spinel-ebpf-deps records, and NANOPB_DIR naming nanopb-0.4.9.1.
# The in-process codegen that several minitest files compile through
# (build/codegen_c/spinel-ebpf-cc) is linked here from vendor/spinel's build.
#
# A failure, an error or a skip fails the file, and each one is printed with
# its test name and minitest's reason.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
E=$(cd "$HERE/../../tools/ebpf" && pwd)
: "${NANOPB_DIR:?set NANOPB_DIR to nanopb-0.4.9.1 (docs/toolchains/spinel-ebpf-deps)}"
export NANOPB_DIR LANG=C.UTF-8
W=${EBPF_WORK:-${TMPDIR:-/tmp}/spinel-ebpf}
mkdir -p "$W"
# spinel-llvm's MLIR lane and its product gate (a sibling checkout this
# repository may not depend on), and the harness-only semantic model.
EXCLUDED="test_spbpf_product_gate.rb test_mlir_object_shadow.rb test_otlp_semantic_model.rb"
RUNTIME="egress_contract oneshot otlp_endpoint otlp_enrich probe_capability record_mirror record_span_parity"

t_all=$(date +%s); failed=""
make -C "$E/src/codegen_c" > "$W/codegen_c.log" 2>&1 || { echo "codegen_c: build failed ($W/codegen_c.log)"; exit 1; }

# The in-process codegen. Mirrors bin/spinel-ebpf's inproc_codegen_bin (the
# predecessor built it in its container, tools/stage2_verify.sh): the pinned
# compiler's objects without main.o, its regexp engine, libprism, and librbs
# when present. Linked on every run, so a binary from another vendor build is
# never used; a failed link stops the suite.
SP=$(cd "$E/../../vendor/spinel" && pwd)
ICC="$E/build/codegen_c/spinel-ebpf-cc"
rm -f "$ICC"
set --
for o in "$SP"/build/csrc/*.o "$SP"/build/regexp/*.o; do
  case $o in */csrc/main.o) continue ;; esac
  [ -f "$o" ] && set -- "$@" "$o"
done
[ $# -gt 0 ] && [ -f "$SP/build/libprism.a" ] ||
  { echo "in-process codegen: vendor/spinel is not built (no build/csrc/*.o or build/libprism.a)"; exit 1; }
set -- "$@" "$SP/build/libprism.a"
[ -f "$SP/build/librbs.a" ] && set -- "$@" "$SP/build/librbs.a"
"${CC:-cc}" -O2 -I "$SP/src" "$E/tools/spinel_ebpf_inproc.c" "$E/src/codegen_c/spbpf_schema_adapter.c" \
  "$@" -lm -o "$ICC" > "$W/inproc.log" 2>&1 ||
  { echo "in-process codegen: link failed ($W/inproc.log)"; exit 1; }

t0=$(date +%s); runs=0; fails=0; errs=0; skips=0; files=0
for t in "$E"/tests/spinel_ebpf/*_test.rb "$E"/tests/spinel_ebpf/test_*.rb; do
  b=$(basename "$t")
  case " $EXCLUDED " in *" $b "*) continue ;; esac
  (cd "$E" && ruby -Isrc -Itests "$t" -v) > "$W/minitest.out" 2>&1
  line=$(grep -E '^[0-9]+ runs, ' "$W/minitest.out" | tail -1)
  set -- $(printf '%s\n' "$line" | tr -d ',' | awk '{print $1, $5, $7, $9}')
  if [ $# -ne 4 ]; then echo "  $b: no summary line"; errs=$((errs + 1)); failed="$failed $b"; continue; fi
  files=$((files + 1)); runs=$((runs + $1)); fails=$((fails + $2)); errs=$((errs + $3)); skips=$((skips + $4))
  [ "$2$3$4" = 000 ] || {
    echo "  $b: $line"; failed="$failed $b"
    # minitest prints each as "  N) Skipped:", then "Class#test [file:line]:",
    # then the reason
    awk -v f="$b" '/^ +[0-9]+\) (Skipped|Failure|Error):$/ { k = tolower($2); sub(/:$/, "", k); getline n; getline r; sub(/ \[.*$/, "", n); print "    " k " " f ": " n ": " r }' "$W/minitest.out"
  }
done
echo "minitest: $files files, $runs runs, $fails failures, $errs errors, $skips skips [$(( $(date +%s) - t0 )) s]"

t0=$(date +%s); rp=0
for n in $RUNTIME; do
  if (cd "$E" && bash "tests/runtime/run_$n.sh") > "$W/runtime-$n.log" 2>&1; then rp=$((rp + 1))
  else echo "  runtime $n failed; see $W/runtime-$n.log"; failed="$failed runtime:$n"; fi
done
echo "runtime harnesses: $rp of $(echo $RUNTIME | wc -w) pass [$(( $(date +%s) - t0 )) s]"
echo "total wall: $(( $(date +%s) - t_all )) s"
if [ -n "$failed" ]; then echo "run: failed:$failed"; exit 1; fi
echo "run: every check passed"
