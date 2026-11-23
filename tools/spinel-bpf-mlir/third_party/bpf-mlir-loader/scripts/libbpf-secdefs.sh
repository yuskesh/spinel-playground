#!/bin/bash
# scripts/libbpf-secdefs.sh — libbpf の section_defs (libbpf.c の SEC_DEF の行) から「順・名前・SEC_EXP_ATTACH_OPT (SEC_ATTACHABLE_OPT を含む) の有無」
# の表を抜く (E019 — src/load/secdefs.c の写しを gate が比べる。libbpf を上げたら表の違いで落ちる)。
#
#   scripts/libbpf-secdefs.sh [libbpf.c]     # 出力は "<名前>\t<0|1>" の行
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE/third_party/libbpf/src/libbpf.c}"
awk '/^static const struct bpf_sec_def section_defs\[\] = \{/{on=1; next} on && /^\};/{on=0} on && /SEC_DEF\(/' "$SRC" |
  sed -E 's/^[[:space:]]*SEC_DEF\("([^"]*)",[^,]*,[^,]*,([^,)]*).*/\1\t\2/' |
  awk -F'\t' '{ print $1 "\t" (($2 ~ /SEC_EXP_ATTACH_OPT|SEC_ATTACHABLE_OPT/) ? 1 : 0) }'
