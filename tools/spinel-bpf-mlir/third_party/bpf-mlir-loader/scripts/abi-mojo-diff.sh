#!/bin/bash
# scripts/abi-mojo-diff.sh — mojo の面の群 (scripts/abi-mojo.tsv) の Go の loader との差動: test/abi/<群>_diff.c を mojo の Go の loader の
# 試験の c-archive (scripts/mojo-oracle.sh) と bml に link した 2 つの driver を作り (build)、abi-mojo-target.sh の 2 つの出力を比べる
# (compare — 表の名指しの差の外の差は失敗)。E012 の trace-diff.sh を群で一般にしたもの (E013)。
#
#   scripts/abi-mojo-diff.sh build <群>...         build/tmp/abi-mojo/drv/drv_<群>_{mojo,bml}
#   scripts/abi-mojo-diff.sh compare <群> <dir>     (abi-mojo-target.sh の <出力の親>/<kernel>/<群>)
set -uo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/abi-mojo-diff.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$HERE/build/tmp/abi-mojo/drv"
O="$HERE/build/tmp/mojo-oracle"
L="$HERE/build/libs"
named() { awk -F'\t' -v g="$1" '$1==g{print $6}' "$HERE/scripts/abi-mojo.tsv"; }
case "${1:-}" in
build)
  shift
  [ -f "$O/libmojobpf_test.a" ] || { echo "abi-mojo-diff: $O/libmojobpf_test.a が無い (scripts/mojo-oracle.sh)" >&2; exit 1; }
  mkdir -p "$W"
  CF=(-O1 -g -std=gnu11 -Wall -Wextra -Werror -I"$HERE/include")
  for g in "$@"; do
    gcc "${CF[@]}" -DMOJO -o "$W/drv_${g}_mojo" "$HERE/test/abi/${g}_diff.c" "$O/libmojobpf_test.a" -lpthread || exit 1
    if grep -q 'bml_testonly_' "$HERE/test/abi/${g}_diff.c"; then # E017: 試験の口の群は試験の build (-DBML_TEST_CAPS の src) に link
      # shellcheck disable=SC2046
      gcc "${CF[@]}" -DBML_TEST_CAPS -I"$HERE/src" -I"$HERE/third_party/libbpf/include/uapi" -I"$L/include" -o "$W/drv_${g}_bml" "$HERE/test/abi/${g}_diff.c" \
        $("$HERE/scripts/srcs.sh" src) "$L/lib/libbpf.a" "$L/lib/libelf.a" "$L/lib/libz.a" -lpthread || exit 1
    else
      gcc "${CF[@]}" -o "$W/drv_${g}_bml" "$HERE/test/abi/${g}_diff.c" "$L/lib/libbml.a" "$L/lib/libbpf.a" "$L/lib/libelf.a" "$L/lib/libz.a" -lpthread || exit 1
    fi
  done
  echo "abi-mojo-diff: build ok $* ($(cut -c1-12 "$O/commit"))" ;;
compare)
  G="${2:?}"; D="${3:?}"
  NAMED=$(named "$G"); [ "$NAMED" = - ] && NAMED='^$never'
  a=$(grep -vE "$NAMED" "$D/diff-mojo.txt"); b=$(grep -vE "$NAMED" "$D/diff-bml.txt")
  na=$(grep -E "$NAMED" "$D/diff-mojo.txt"); nb=$(grep -E "$NAMED" "$D/diff-bml.txt")
  if [ -z "$a" ] || [ "$a" != "$b" ]; then diff <(echo "$a") <(echo "$b"); echo "abi-mojo-diff $G $D: 名指しの外の差 — FAIL"; exit 1; fi
  echo "abi-mojo-diff $G $D: 行 $(echo "$a" | wc -l) 一致、名指しの差: mojo「$na」/ bml「$nb」 — ok" ;;
*) echo "abi-mojo-diff: build <群>... | compare <群> <dir>" >&2; exit 2 ;;
esac
