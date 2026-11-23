#!/bin/bash
# scripts/split-load-target.sh — E055 の H7 (root で): 分けた DWARF の uprobe の ELF (test/abi/fixture/e55_args.mlir — 本体の sha256 は作った fixture
# のもの) を製品の照合する load (bml_load_checked_targets — build/tools/checked_load の targets の JSON: debug_root と uprobe_targets[].debug) で
# load だけ (attach も test run もしない)、root と CAP_BPF + CAP_PERFMON (uid 1000) で。同じ権限の Go の ebpf-precheck --live --binary --debug /
# --debug-root と、result の kind と止める Unmet の kind の列を比べる (E053 の checked-load-target.sh の形)。
#
#   sudo scripts/split-load-target.sh <作業の dir> <TOOLS_DIR> <ebpf-compile>
#
# 出力の行: "<権限> <組> kind=N unmet=…" (C) と "<権限> <組> go <result> unmet=…"、最後に "same" か "DIFF"。
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="${1:?}"; T="$(cd "${2:?}" && pwd)"; EC="${3:?}"
[ "$(id -u)" = 0 ] || { echo "split-load-target: root で" >&2; exit 2; }
case "$W" in /*) ;; *) W="$PWD/$W" ;; esac
U="${SUDO_UID:-1000}"
S="$W/fx"
rm -rf "$W"; mkdir -p "$W"
"$HERE/scripts/split-fixtures.sh" "$S" > /dev/null || exit 1
sha=$(sha256sum "$S/stripped" | cut -d' ' -f1)
jq --arg s "$sha" '.core.programs[0].binary_sha256 = $s' "$HERE/test/abi/fixture/e55_args.schema.json" > "$W/schema.jsn"
"$EC" "$HERE/test/abi/fixture/e55_args.mlir" --schema "$W/schema.jsn" -o "$W/e55_args.bpf.o" || exit 1
ssha=$(sha256sum "$W/schema.jsn" | cut -d' ' -f1)
M="$HERE/test/abi/fixture/e54-undeclared.maps.json"
chmod -R a+rX "$W"
kind() { case "$1" in ok) echo 0;; precheck_failed) echo 2;; target_rejected) echo 3;; verifier_rejected) echo 4;; *) echo "?$1";; esac; }
# 組: 名前|targets の JSON の追加 (debug と debug_root)|Go の flag
CASES=(
  "override|\"debug\":\"$S/whole.debug\"||--debug=count=$S/whole.debug"
  "root||,\"debug_root\":\"$S/root\"|--debug-root=$S/root"
  "root_default|||"
  "root_empty||,\"debug_root\":\"\"|--debug-root="
  "badid|\"debug\":\"$S/badid.debug\"||--debug=count=$S/badid.debug"
  "badcrc|\"debug\":\"$S/badcrc.debug\"||--debug=count=$S/badcrc.debug"
  "missing|\"debug\":\"$S/missing.debug\"|,\"debug_root\":\"$S/root\"|--debug-root=$S/root --debug=count=$S/missing.debug"
)
bad=0
for p in root bpf,perfmon; do
  run=()
  [ "$p" = root ] || run=(setpriv --reuid="$U" --regid="$U" --clear-groups --inh-caps=-all,+bpf,+perfmon --ambient-caps=-all,+bpf,+perfmon --bounding-set=-all,+bpf,+perfmon)
  for c in "${CASES[@]}"; do
    IFS='|' read -r name dbg droot gof <<< "$c"
    printf '{"uprobe_targets":[{"program":"count","path":"%s"%s}]%s}\n' "$S/stripped" "${dbg:+,$dbg}" "$droot" > "$W/$name.targets"
    cl=$("${run[@]}" "$T/checked_load" "$W/e55_args.bpf.o" "$ssha" "$M" "$W/$name.targets")
    # shellcheck disable=SC2086
    g=$("${run[@]}" "$T/ebpf-precheck" --loader=cilium-v0.22-usdt-ksyscall --live --binary=count="$S/stripped" $gof --schema-sha256="$ssha" --maps="$M" "$W/e55_args.bpf.o" |
      jq -r '"\(.result) unmet=\([.unmet[] | select(.blocks_load) | .kind] | join(","))"')
    echo "$p $name ${cl#* }"
    echo "$p $name go $g"
    [ "${cl#* }" = "kind=$(kind "${g%% *}") ${g#* }" ] || { echo "DIFF $p $name"; bad=1; }
  done
done
chown -R "$U" "$W"
[ "$bad" = 0 ] && echo same || echo DIFF
exit $bad
