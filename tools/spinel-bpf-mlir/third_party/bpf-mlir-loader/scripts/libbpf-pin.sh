#!/bin/bash
# scripts/libbpf-pin.sh — guard (src/load/ — E005) が依る libbpf の source の hash の固定 (H5)。libbpf を上げると gate が落ち、guard の
# 前提 (sanitize の判定と書き換え・B2 の BTF の破棄・M1 の map の BTF の外し・P1 の helper の置き換え・feat_supported と kern_feature_id の
# 値・memlock と token の option) の再監査を強いる。file の全体の hash (範囲より厳しい — 版の上げは全て再監査)。
#
#   scripts/libbpf-pin.sh [--check] [LIBBPF_SRC_DIR]     # 既定 third_party/libbpf/src。--check は表と比べる、無しは表を書く
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TABLE="$HERE/scripts/libbpf-pin.tsv"
CHECK=0
[ "${1:-}" != "--check" ] || { CHECK=1; shift; }
SRC="${1:-$HERE/third_party/libbpf/src}"
FILES="libbpf.c features.c libbpf_internal.h bpf.c btf.c"
gen() {
  echo "# libbpf-pin.tsv — written by scripts/libbpf-pin.sh (libbpf v1.7.0 f5dcbae7). file and sha256. Guard preconditions: libbpf.c (btf_needs_sanitization, sanitize_btf, "BTF is optional", dropping map BTF, helper substitution, kernel_supports), features.c (feat_supported and the probes), libbpf_internal.h (enum kern_feature_id values, LBF_* in src/load/internal.h), bpf.c (libbpf_set_memlock_rlim, bump_rlimit_memlock), btf.c (BTF parsing and raw bytes)"
  for f in $FILES; do printf '%s\t%s\n' "$f" "$(sha256sum < "$SRC/$f" | cut -d' ' -f1)"; done
}
if [ "$CHECK" = 1 ]; then
  cmp -s <(gen) "$TABLE" || { echo "libbpf-pin: the libbpf source the guard depends on differs from the pinned table ($SRC); re-audit the guard preconditions and rewrite the table" >&2; diff <(gen) "$TABLE" >&2 || true; exit 1; }
  echo "ok: the libbpf source matches the pinned table ($(echo $FILES | wc -w) files)"
else
  gen > "$TABLE"
fi
