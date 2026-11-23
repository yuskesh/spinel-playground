#!/bin/bash
# scripts/load-controls.sh — E005 の guard の負の対照と止めない側の対照 (root で)。各々が予測の段で止まる・通ることを確かめる。
#
#   sudo scripts/load-controls.sh [TOOLS_DIR] [MUT_TOOLS_DIR]     # 既定 build/tools build/tools-mut
#
# 1 B2 (BTF の丸ごとの破棄) 2 devmap (M1) 3 libbpf の feature を偽る (4 機能 — predict / sanitize) 4 4 機能の外の書き換え (load の前の
# 照らし合わせを外す変異 — load の後の btf_changed) 5 helper の置き換え (P1 — --unchecked)。偽りは load_case_wrap (-Wl,--wrap=feat_supported)。
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T="${1:-$HERE/build/tools}"; TM="${2:-$HERE/build/tools-mut}"
[ "$(id -u)" = 0 ] || { echo "load-controls: root で走らせる" >&2; exit 2; }
C="$HERE/third_party/bpf-mlir/conformance/requirements/cases"
R="$HERE/third_party/bpf-mlir/docs/experiments/results"
W=$(mktemp -d /dev/shm/load-controls.XXXXXX)
# B2 の ELF: rawtp_ok の .BTF の中の "on_fork" を "on-fork" に (R001 の btfdrop — 識別子でない名前を kernel が拒否する)
cp "$C/rawtp_ok/object.bpf.o" "$W/btfdrop.bpf.o"
read -r off size < <("${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/llvm-readelf" -SW "$W/btfdrop.bpf.o" | awk '$2==".BTF"{print $5, $6}')
off=$((16#$off)); size=$((16#$size)) # llvm-readelf の offset と大きさは 16 進
pos=$(grep -obUa 'on_fork' "$W/btfdrop.bpf.o" | cut -d: -f1 | while read -r p; do [ "$p" -ge "$off" ] && [ "$p" -lt $((off + size)) ] && echo "$p"; done | head -1)
[ -n "$pos" ] || { echo "load-controls: on_fork が .BTF に無い" >&2; exit 1; }
printf '-' | dd of="$W/btfdrop.bpf.o" bs=1 seek=$((pos + 2)) conv=notrunc status=none
fail=0 n=0
expect() { # 名前 期待の段 command…
  local name=$1 want=$2; shift 2
  local got
  got=$("$@" 2>/dev/null | cut -f3 | head -1)
  n=$((n + 1))
  if [ "$got" = "$want" ]; then echo "ok   $name: $got"; else echo "FAIL $name: want $want got $got"; fail=$((fail + 1)); fi
}
X="$C/xdp_ok/object.bpf.o"
U="$R/E135/elf/ustr.bpf.o"
# B2 の対照は guard だけを試す (--unchecked — rawtp_ok の照合は kernel に依る: 6.6 は target_rejected)
expect "B2 の元 (rawtp_ok、--unchecked)" ok "$T/load_case" --unchecked "$C/rawtp_ok/object.bpf.o"
expect "B2 (on-fork、--unchecked)" btf_dropped "$T/load_case" --unchecked "$W/btfdrop.bpf.o"
expect "M1 devmap (E114 dm_redirect)" map_btf "$T/load_case" "$R/E114/elf/dm_redirect.bpf.o"
expect "偽り無し (xdp_ok)" ok env BML_FAKE_MISSING= "$T/load_case_wrap" "$X"
expect "FEAT_BTF_GLOBAL_FUNC を偽る (btf の行に func_global)" predict env BML_FAKE_MISSING=5 "$T/load_case_wrap" "$X"
expect "FEAT_BTF_TYPE_TAG を偽る (TYPE_TAG の型が無い — sanitize の copy は同じ)" ok env BML_FAKE_MISSING=14 "$T/load_case_wrap" "$X"
expect "FEAT_BTF_DECL_TAG を偽る (DECL_TAG の型が無い)" ok env BML_FAKE_MISSING=13 "$T/load_case_wrap" "$X"
expect "FEAT_BTF_ENUM64 を偽る (kflag の ENUM・ENUM64 が無い)" ok env BML_FAKE_MISSING=17 "$T/load_case_wrap" "$X"
expect "FEAT_BTF_QMARK_DATASEC を偽る (6.6 の形 — ? の DATASEC が無い)" ok env BML_FAKE_MISSING=21 "$T/load_case_wrap" "$X"
expect "予測の照らし合わせ無し・FEAT_BTF_GLOBAL_FUNC を偽る (global の FUNC が在る)" sanitize env BML_MUTANT=load.no_predict BML_FAKE_MISSING=5 "$TM/load_case_wrap" "$X"
expect "前の照らし合わせ無し・偽り無し" ok env BML_MUTANT=load.no_pre_features BML_FAKE_MISSING= "$TM/load_case_wrap" "$X"
expect "前の照らし合わせ無し・FEAT_BTF_DATASEC を偽る (4 機能の外)" btf_changed env BML_MUTANT=load.no_pre_features BML_FAKE_MISSING=4 "$TM/load_case_wrap" "$X"
expect "前の照らし合わせ無し・FEAT_BTF_FLOAT を偽る (FLOAT の型が無い — 書き換え無し)" ok env BML_MUTANT=load.no_pre_features BML_FAKE_MISSING=11 "$TM/load_case_wrap" "$X"
expect "helper 114 の ELF (--unchecked)・偽り無し" ok env BML_FAKE_MISSING= "$T/load_case_wrap" --unchecked "$U"
expect "helper 114 の ELF・FEAT_PROBE_READ_KERN を偽る" rewrite env BML_FAKE_MISSING=8 "$T/load_case_wrap" --unchecked "$U"
# P3 (internal map の BPF_F_MMAPABLE を libbpf が外す): .rodata を持つ E097 の rodata_count で FEAT_ARRAY_MMAP (6) を偽る
RO="$R/E097/elf/rodata_count.bpf.o"
expect "FEAT_ARRAY_MMAP を偽る (.rodata)" rewrite env BML_FAKE_MISSING=6 "$T/load_case_wrap" "$RO"
expect "前の照らし合わせ無し・FEAT_ARRAY_MMAP を偽る (.rodata — load の後)" map_flags env BML_MUTANT=load.no_pre_features BML_FAKE_MISSING=6 "$TM/load_case_wrap" "$RO"
expect "前の照らし合わせ無し・偽り無し (.rodata)" ok env BML_MUTANT=load.no_pre_features BML_FAKE_MISSING= "$TM/load_case_wrap" "$RO"
# E019: FEAT_EXP_ATTACH_TYPE (7) の欠けは SEC_EXP_ATTACH_OPT の section (xdp) の program だけを書き換える — fentry は止めない、変異
# load.fentry_exp_opt (fentry+ の定義に flag を足す) は fentry を再び止める
FE="$C/fentry_ok/object.bpf.o"
expect "E019 FEAT_EXP_ATTACH_TYPE を偽る (xdp — 書き換える section)" rewrite env BML_FAKE_MISSING=7 "$T/load_case_wrap" "$X"
expect "E019 FEAT_EXP_ATTACH_TYPE を偽る (fentry — libbpf は書き換えない)" ok env BML_FAKE_MISSING=7 "$T/load_case_wrap" "$FE"
expect "E019 変異 load.fentry_exp_opt・FEAT_EXP_ATTACH_TYPE を偽る (fentry)" rewrite env BML_MUTANT=load.fentry_exp_opt BML_FAKE_MISSING=7 "$TM/load_case_wrap" "$FE"
rm -rf "$W"
echo "load-controls: $(uname -r) $n 対照 fail=$fail"
[ "$fail" -eq 0 ]
