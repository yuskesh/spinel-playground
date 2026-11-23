#!/bin/bash
# scripts/gate.sh [--full|--static] — commit の前の gate。使い分けは docs/tools/gate.md。
# --full: verified の鍵を無視して全ての段 (bpf-mlir の版の取り込みと計画の完成の前に必ず — E011)。VERIFIED_RECORD=E<n> で通った重い段の鍵を scripts/verified.tsv に。
#
# E001: 静的な library の build・再現 (別の directory の 2 回目と byte 比較)・最小の実行 file の NEEDED と import・
#       process の状態 (rlimit・signal・thread) を変えないこと + その変異の対照。sudo は要らない。
# 以後の実験が段を足す。
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/gate.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/gate-mode.sh"
. "$HERE/scripts/gate-case-order.sh"
gate_mode_init "$@"
export TMPDIR="${GATE_VM_TMP:-$HERE/build/tmp}"
mkdir -p "$TMPDIR"
# 各段の所要の秒 (前の段の終わりに) と全体 — 下流の検証の見積もり (利用者の指示 2026-09-27)
step() { vm_stage_close; [ -z "${_gate_t:-}" ] || printf '   [%ds]\n' $((SECONDS - _gate_t)); _gate_t=$SECONDS; printf '\n== gate: %s\n' "$*"; }
die() { echo "gate: FAIL: $*" >&2; exit 1; }
bash "$HERE/scripts/check-mutation-inventory.sh"
# E011 H3: verified の鍵 (mojo-bpf-mlir P023 E089 の形)。重い差動の段は、入力の鍵 (src・cmd・include・shim・test・scripts の中身・bpf-mlir の
# submodule の commit・kernel の版の sha256) が scripts/verified.tsv に在れば飛ばす。`scripts/gate.sh --full` (か GATE_FULL=1) は鍵を無視して
# 全て、`VERIFIED_RECORD=E<n>` で通った段の鍵を足す。**bpf-mlir の版の取り込みと計画の完成の前は必ず --full** (CLAUDE.md)
VKEY=$({ (cd "$HERE" && find src cmd include shim test scripts -type f ! -name verified.tsv -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
         git -C "$HERE/third_party/bpf-mlir" rev-parse HEAD; uname -r; } | sha256sum | cut -c1-64)
verified() { [ "$GATE_MODE" != static ] && [ "${GATE_FULL:-0}" != 1 ] && grep -q "^$1	$VKEY	" "$HERE/scripts/verified.tsv" 2>/dev/null && echo "skip: verified の鍵 ($1 — ${VKEY:0:12}) — --full で走らせる"; }
vrecord() { [ "$GATE_MODE" = static ] || [ -z "${VERIFIED_RECORD:-}" ] || printf '%s\t%s\t%s\n' "$1" "$VKEY" "$VERIFIED_RECORD" >> "$HERE/scripts/verified.tsv"; }
# rsudo は scripts/gate-vm.sh (--vm-root の転送と同じ所に — E068)

# 同じ tree の gate を直列に (build/ の生成物・fuzz の corpus を奪い合わない — bpf-mlir E300 と同じ形。レビュー役の候補)
exec 9> "$HERE/build/.gate.lock"
flock -n 9 || { echo "gate: 別の gate がこの tree で走っている — 待つ" >&2; flock 9; }

if [ "$GATE_MODE" != vm-root ]; then # E068: 非 root の検証の段は --static が受け持つ (--vm-root は root の 20 段とその準備だけ)
step "構造: 1 つの file は 500 行まで (利用者の指示 — 例外は理由付きの表 scripts/line-limit-exceptions.tsv)"
bash "$HERE/scripts/check-gate-mode.sh"
bash "$HERE/scripts/check-gate-privilege.sh" # E068
bash "$HERE/scripts/gate-vm-unit.sh" "$(mktemp -u "$TMPDIR/gate-vm-unit.XXXXXX")" > "$TMPDIR/gate-vm-unit.txt" 2>&1 || { cat "$TMPDIR/gate-vm-unit.txt"; die "E068: --vm-root の転送の wire の対照"; }
bash "$HERE/scripts/check-gate-storage.sh"
limit=500
over=""
while read -r n f; do
  [ "$f" = total ] && continue
  rel=${f#"$HERE"/}
  if [ "$n" -gt "$limit" ] && ! grep -q "^$rel	" "$HERE/scripts/line-limit-exceptions.tsv" 2>/dev/null; then
    over="$over $rel($n)"
  fi
done < <(find "$HERE/src" "$HERE/cmd" "$HERE/include" "$HERE/test" "$HERE/scripts" -type f \( -name '*.c' -o -name '*.h' -o -name '*.go' -o -name '*.sh' \) -print0 | xargs -0 wc -l)
[ -z "$over" ] || die "500 行を超える file:$over — 責務で分けるか、例外の表に理由を"
# 例外の表の行は実在の file を指すこと
while IFS=$'\t' read -r rel why; do
  case "$rel" in ''|'#'*) continue ;; esac
  [ -f "$HERE/$rel" ] || die "例外の表の $rel が無い"
  [ -n "$why" ] || die "例外の表の $rel に理由が無い"
done < "$HERE/scripts/line-limit-exceptions.tsv"
echo "ok (上限 $limit 行、例外 $(grep -cv '^#' "$HERE/scripts/line-limit-exceptions.tsv" || true) 件)"

step "build-libs (build/libs)"
"$HERE/scripts/build-libs.sh" "$HERE/build/libs" >/dev/null

step "再現: build/tmp/gate-repro に 2 回目、.a を byte で比べる"
"$HERE/scripts/build-libs.sh" "$TMPDIR/gate-repro" >/dev/null
for a in libz.a libelf.a libbpf.a libbml.a libbml_spinel.a; do
  cmp -s "$HERE/build/libs/lib/$a" "$TMPDIR/gate-repro/lib/$a" || die "$a が 2 回の build で違う"
  echo "same: $a $(sha256sum "$HERE/build/libs/lib/$a" | cut -c1-16)"
done

step "library の未定義の symbol: signal・thread の作成・atexit を参照しない、rlimit は setrlimit64 だけ、pthread は mutex だけ (E006 の registry — trylock は追補の 2 の close は待たない)。thread の作成は abi_trace.o (bml_test_run_tracing の join する 1 つの thread — E012) だけ"
PAT='^(sig[a-z]*|bsd_signal|sysv_signal|pthread_[a-z_]+|atexit|__cxa_atexit|prctl|clone[0-9]*|fork|setrlimit[0-9]*|prlimit[0-9]*)$'
refs=$(for a in libz.a libelf.a libbpf.a libbml.a libbml_spinel.a; do nm -A "$HERE/build/libs/lib/$a" 2>/dev/null | awk '$(NF-1)=="U"{n=split($1,p,":"); print p[n-1], $NF}'; done)
ext=$(printf '%s\n' "$refs" | awk '$1!="abi_trace.o"{print $2}' | sort -u | grep -E "$PAT" | tr '\n' ' ' || true)
[ "$ext" = "pthread_mutex_init pthread_mutex_lock pthread_mutex_trylock pthread_mutex_unlock setrlimit64 " ] || die "期待 (setrlimit64 と pthread の mutex だけ) と違う参照: '$ext'"
# E012 (レビュー役の決定 2026-09-28): 許しは file ごと — 他の file に thread の作成が漏れない
tr_ext=$(printf '%s\n' "$refs" | awk '$1=="abi_trace.o"{print $2}' | sort -u | grep -E "$PAT" | tr '\n' ' ' || true)
[ "$tr_ext" = "pthread_attr_destroy pthread_attr_init pthread_attr_setsigmask_np pthread_create pthread_join sigfillset " ] ||
  die "abi_trace.o の参照が期待 (join する thread と signal を全て block する attr だけ) と違う: '$tr_ext'"
if nm "$HERE/build/libs/lib/libbml.a" 2>/dev/null | grep 'bml_testonly_' > /dev/null; then die "libbml.a に試験の口 (bml_testonly_)"; fi # E050: grep -q は pipefail で SIGPIPE — 見逃す
[ ! -e "$HERE/build/libs/include/bml/bml_testonly.h" ] || die "配る header に試験の口の bml_testonly.h (E017)"
echo "ok: $ext / abi_trace.o: $tr_ext"

step "最小の実行 file (measure-min)"
"$HERE/scripts/measure-min.sh" "$HERE/build/libs"

step "process の状態: 権限の無い load で rlimit・signal・thread に触れない + 対照"
ELF="$HERE/third_party/bpf-mlir/conformance/requirements/cases/answer_missing/object.bpf.o"
[ -f "$ELF" ] || die "試験の ELF が無い: $ELF"
L="$HERE/build/libs"
gcc -O2 -std=gnu11 -I"$L/include" -DMIN_CONTROL_NO_MEMLOCK_OPT -o "$HERE/build/min/min.ctl" "$HERE/test/min/min.c" \
  "$L/lib/libbml.a" "$L/lib/libbpf.a" "$L/lib/libelf.a" "$L/lib/libz.a"
if [ "$(id -u)" = 0 ]; then die "権限の無い user で走らせる (対照は権限の無い probe の失敗に依る)"; fi
rc=0; strace -f -qq -o "$TMPDIR/gate-min.st" "$HERE/build/min/min" "$ELF" >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || die "min の rc が $rc (期待: 権限の無い load の失敗で 1)"
if grep -E 'setrlimit|prlimit64\(0, RLIMIT_MEMLOCK|rt_sigaction|sigaltstack|clone|fork' "$TMPDIR/gate-min.st"; then
  die "min が rlimit・signal・thread の syscall を呼んだ"
fi
echo "ok: min は RLIMIT_MEMLOCK・rt_sigaction・clone を呼ばない"
crc=0; strace -f -qq -o "$TMPDIR/gate-ctl.st" "$HERE/build/min/min.ctl" "$ELF" >/dev/null 2>&1 || crc=$?
[ "$crc" = 1 ] || die "対照の min.ctl の rc が $crc (期待: 権限の無い load の失敗で 1 — || true は本当の失敗も飲む、レビュー役の P3)"
grep -q 'prlimit64(0, RLIMIT_MEMLOCK' "$TMPDIR/gate-ctl.st" ||
  die "対照 (libbpf_set_memlock_rlim(0) を外した min) が RLIMIT_MEMLOCK に触れない — 上の検査が効いていない"
echo "ok: 対照は RLIMIT_MEMLOCK を上げようとした (検査が効いている)"

step "E007: 製品の libbml.a に spinel の shim (spinelbpf_*) が無い — shim は libbml_spinel.a だけ"
if nm "$HERE/build/libs/lib/libbml.a" 2>/dev/null | grep ' T spinelbpf_' > /dev/null; then die "libbml.a に spinelbpf_ の symbol"; fi
[ "$(nm "$HERE/build/libs/lib/libbml_spinel.a" 2>/dev/null | grep -c ' T spinelbpf_')" = 28 ] || die "libbml_spinel.a の spinelbpf_ の export が 28 (25 + P009 の per-CPU 3) でない"
echo "ok"

step "E002: 製品の libbml.a に変異の hook が無い"
if nm "$HERE/build/libs/lib/libbml.a" 2>/dev/null | grep 'bml_mutant' > /dev/null; then die "libbml.a に bml_mutant の symbol"; fi
if strings -a "$HERE/build/libs/lib/libbml.a" | grep 'BML_MUTANT' > /dev/null; then die "libbml.a に BML_MUTANT の文字列"; fi
echo ok
step "E002: parse の corpus (release・ASan + UBSan)"
"$HERE/scripts/build-tools.sh" release >/dev/null
"$HERE/scripts/build-tools.sh" asan >/dev/null
"$HERE/scripts/build-tools.sh" mut >/dev/null
bash "$HERE/scripts/reader-unit.sh" "$(mktemp -d "$TMPDIR/reader-unit.XXXXXX")/run"
bash "$HERE/scripts/arena-unit.sh" "$(mktemp -d "$TMPDIR/arena-unit.XXXXXX")/run"
bash "$HERE/scripts/p152-unit.sh" "$(mktemp -d "$TMPDIR/p152-unit.XXXXXX")/run"
"$HERE/scripts/corpus-parse.sh" "$HERE/build/tools"
"$HERE/scripts/corpus-parse.sh" "$HERE/build/tools-asan"
step "E002: JSON の単体の試験 (ASan + UBSan — 厳しさの 5 類・失敗の経路の解放)"
"${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang" -O1 -g -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
  -I"$HERE/src" -I"$HERE/include" -I"$HERE/third_party/libbpf/include/uapi" -I"$HERE/build/libs/include" -o "$HERE/build/tools-asan/json_test" "$("$HERE/scripts/srcs.sh" test json_test)" $("$HERE/scripts/srcs.sh" src) \
  "$HERE/build/libs/lib/libbpf.a" "$HERE/build/libs/lib/libelf.a" "$HERE/build/libs/lib/libz.a"
"$HERE/build/tools-asan/json_test"

step "E060: parse.version_max19 (上限+1) は header_unknown_version_33 だけで落ちる"
mrc=0; BML_MUTANT=parse.version_max19 "$HERE/scripts/corpus-parse.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-mut.txt" 2>&1 || mrc=$?
[ "$mrc" -eq 1 ] || die "変異 parse.version_max19 の corpus-parse の rc が 1 でない: $mrc"
[ "$(grep '^DIFF' "$TMPDIR/gate-mut.txt" | awk '{print $2}' | tr -d : | tr '\n' ' ')" = "header_unknown_version_33 " ] ||
  die "変異が意図した case で落ちていない: $(grep '^DIFF' "$TMPDIR/gate-mut.txt" | head -3)"
echo "ok: header_unknown_version_33"

step "E002: C と Go の差動 (parse・ELF の読み・JSON — 小さい回、ASan + UBSan の build も)"
"$HERE/scripts/diff-parse.sh" 7 30
"$HERE/scripts/diff-parse.sh" 8 10 "$HERE/build/tools-asan"
"$HERE/scripts/diff-elf.sh" 7 30
"$HERE/scripts/diff-elf.sh" 8 10 "$HERE/build/tools-asan"
"$HERE/scripts/diff-json.sh" 7 5
"$HERE/scripts/diff-json.sh" 8 3 "$HERE/build/tools-asan"
"$HERE/scripts/diff-usdt.sh" 1 2000 && "$HERE/scripts/diff-usdt.sh" 7 3000 "$HERE/build/tools-asan" # E039: USDT の note と引数の記述

step "E002: json の corpus (§13)"
"$HERE/scripts/corpus-json.sh" "$HERE/build/tools"
"$HERE/scripts/corpus-json.sh" "$HERE/build/tools-asan"

step "E002: cases の corpus (記録した caps — release・ASan + UBSan、PENDING は名指しの表の DWARF の 6 case だけ — 版 3 の 2 と版 4 の E306 の 4)"
"$HERE/scripts/corpus-cases.sh" "$HERE/build/tools"
"$HERE/scripts/corpus-cases.sh" "$HERE/build/tools-asan"

step "E002 / E008 / E032 / E036 / E039 / E041: 変異の対照 — check.unknown_not_blocking で corpus-cases が止める Unknown の 63 case (E042 の tpbuf の attach_unknown 2、E041 の v13 の 13 と progattach の双子 3、E039 の v12 の 10 と cilium-v0.22-usdt の双子 2、E036 の版 11 の 7 つ・v0.16.0 の双子 kprobe_wrong_arch__bml-libbpf-v1.7・v0.17.0 の fentry_farg_no_probe・E008 の uprobe_lang_unknown (uprobearg_abi_unknown)・E032 の uretprobe_lang_unknown・uretprobe_no_dwarf (uretprobe_abi_unknown)・v10_fmodret_no_func_sig (retsig_unknown)・v10_fmodret_no_func_param (farg_unknown) を含む) で落ちる、dwarf.lang_always_c で uprobe_go_function・uprobe_lang_unknown・uretprobe_go_function・uretprobe_lang_unknown だけが落ちる (E032 — uretprobe の判定は uprobe_abi を共有)"
mrc=0; BML_MUTANT=check.unknown_not_blocking "$HERE/scripts/corpus-cases.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-mut2.txt" 2>&1 || mrc=$?
[ "$mrc" = 1 ] || die "check.unknown_not_blocking: rc1でない: $mrc"
# E047: 63 → 71 (fentry_scalar 3・v15_strptr_no_probe・ksyscall の組 4)、E052: → 75 (usdt-ksyscall 4)、E053: → 83 (v16 8)、E054: → 86 (v17 3)、E055: → 90 (split_debug 4)、E057: → 91
unknown_ids=$(jq -r 'select(any(.unmet[]?; (.kind | endswith("_unknown")) and .blocks_load)) | input_filename | split("/")[-2]' "$HERE"/third_party/bpf-mlir/conformance/requirements/cases/*/want.json) && gate_case_ids_match check.unknown_not_blocking 1 "$(gate_read_diff_ids "$TMPDIR/gate-mut2.txt")" "$unknown_ids" || die "止める Unknown の exact case 集合が原本の want と違う"
# E032 の 4 つと E036 の 7 つ (版 11 の止める Unknown — tpfield_unknown・ext_target_unknown・structop_unknown・farg_unknown・arch_unknown)
for c in uretprobe_lang_unknown uretprobe_no_dwarf v10_fmodret_no_func_sig v10_fmodret_no_func_param \
         v11_ext_no_target v11_ext_recorded v11_lsm_no_func_args v11_perf_no_arch v11_sops_no_probe v11_tp_caps4 v11_tp_unreadable \
         v12_usdt_rip v12_usdt_caps6 v12_usdt_cilium__bml-libbpf-v1.7; do
  grep -q "^DIFF $c:" "$TMPDIR/gate-mut2.txt" || die "E032 / E036: 止める Unknown の case $c が変異 check.unknown_not_blocking で落ちていない"
done
grep -q "^DIFF uprobe_lang_unknown:" "$TMPDIR/gate-mut2.txt" || die "uprobearg_abi_unknown の BlocksLoad の確認が落ちていない"
# 落ちるのが予測 — rc は 1 (比べの差) の時だけ通し、下で組を見る (|| true は本当の失敗も飲む — レビュー役の P3)
lrc=0; BML_MUTANT=dwarf.lang_always_c "$HERE/scripts/corpus-cases.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-mut-lang.txt" 2>&1 || lrc=$?
[ "$lrc" -eq 1 ] || { tail -5 "$TMPDIR/gate-mut-lang.txt"; die "変異 dwarf.lang_always_c の corpus-cases の rc が 1 でない: $lrc"; }
[ "$(grep '^DIFF' "$TMPDIR/gate-mut-lang.txt" | cut -d: -f1 | tr '\n' ' ')" = "DIFF uprobe_go_function DIFF uprobe_lang_unknown DIFF uretprobe_go_function DIFF uretprobe_lang_unknown DIFF v12_uretmulti_go_function " ] ||
  die "変異 dwarf.lang_always_c の落ちる case が予測と違う: $(grep '^DIFF' "$TMPDIR/gate-mut-lang.txt" | cut -d: -f1 | tr '\n' ' ')"
echo "ok: 71 case・lang_always_c は 5 case (E032 の uretprobe の 2 つと E039 の uretprobe_multi を含む)"
# E027 (判定の版 6 — bpf-mlir E362): tp_btf の NULL の引数の照合は struct の引数だけ・Unmet は index ごと
for mf in "check.nullable_all_args:rawtp_ints_not_marked rawtp_mixed_not_marked rawtp_unread_no_probe rawtp_unread_not_marked " \
          "check.nullable_single_unmet:rawtp_mixed_not_marked rawtp_nullable_no_probe rawtp_nullable_not_marked rawtp_nullable_unknown "; do
  nrc=0; BML_MUTANT="${mf%%:*}" "$HERE/scripts/corpus-cases.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-mut-null.txt" 2>&1 || nrc=$?
  got=$(grep '^DIFF' "$TMPDIR/gate-mut-null.txt" | awk '{print $2}' | tr -d : | tr '\n' ' ' || true)
  [ "$nrc" -eq 1 ] && [ "$got" = "${mf#*:}" ] || die "E027: 変異 ${mf%%:*} の落ちる case が予測と違う (rc $nrc): $got"
done
echo "ok: E027 の変異 nullable_all_args・nullable_single_unmet は各 4 case"
# E031 (形式の版 9・判定の版 7 — bpf-mlir E388): E388 の v9 の 9 case は同じ requirements (機構の名前 raw_tp・ctxaccess 2 つを含む)。
# E032 (71695b93): 版 9 の形の網羅の 6 case が足された — 機構の case 3 つ (sched_act・socket・syscall) だけが mechanism_asks_attach_type で、
# ctxaccess を持つ v9_cgroup_egress_type_rejected が ctx_access_ignored で落ちる (iter・sk_lookup の case は落ちない — 機構でも ctxaccess でもない)
V9E388="v9_attach_target_rejected v9_attach_target_unknown v9_attach_type_no_probe v9_attach_type_rejected"
# loader の双子 (requirements は元と同じ): E039 の usdt・E041 の progattach (attach_type が loader に依る kind に)・E047 の ksyscall (名前の順で bml と progattach の間)
V9KA="v9_kretprobe_alias v9_kretprobe_alias__bml-libbpf-v1.7 v9_kretprobe_alias__cilium-v0.22-ksyscall v9_kretprobe_alias__cilium-v0.22-progattach v9_kretprobe_alias__cilium-v0.22-usdt v9_kretprobe_alias__cilium-v0.22-usdt-ksyscall"
TW3="__bml-libbpf-v1.7 __cilium-v0.22-ksyscall __cilium-v0.22-progattach __cilium-v0.22-usdt __cilium-v0.22-usdt-ksyscall";V9ATR=$(for t in $TW3; do printf 'v9_attach_type_rejected%s ' "$t"; done)
V9CTX="$V9E388 ${V9ATR}v9_cgroup_egress_type_rejected $(for t in $TW3; do printf 'v9_cgroup_egress_type_rejected%s ' "$t"; done)v9_ctx_access_rejected $V9KA v9_ok e598_fibflags_helper_unknown_mix e598_fibflags_no_query e598_fibflags_ok e598_fibflags_old_caps e598_fibflags_rejected e598_fibflags_unknown " # E060: six ELF files have ctxaccess; old_caps_no_fib is format5 without it, id_mismatch fails before Check.
# E036: 版 11 の trace_tp の汎用の行は機構の名前 tracepoint — 変異で attach_types を問い記録に鍵が無い (v11_tp_* の 5 — glob の順で v9 の前)
V11TP="v11_tp_caps4 v11_tp_field_mismatch v11_tp_ok v11_tp_syscalls_not_ctx v11_tp_unreadable v16_tpfield_strarray_mismatch v16_tpfield_strarray_no_answer v16_tpfield_strarray_ok v16_tpfield_strarray_unknown v16_tp_strptr_mismatch v16_tp_strptr_no_answer v16_tp_strptr_ok v16_tp_strptr_unknown v17_tp_array_mismatch v17_tp_array_no_answer v17_tp_array_ok v17_tp_array_syscall_ctx v17_tp_array_unknown" # E053 / E054: 版 16 の 8・17 の 5 も同じ
# E037: 判定の版 10 の priv_* の 4 つ (v11 の trace_tp の文書 — priv_differs・priv_no_probed_as は prog_type の Unknown の誤りが先で結果は同じ)
PRIVTP="priv_reprobe_answer_used priv_reprobe_ok priv_reprobe_record_tpfield priv_same"
# E042: tpbuf の ELF (汎用の行 raw_tp_writable — 機構) の 7 と kfunc の syscall の ELF (attach syscall none — 機構) の 6 (glob の順で先頭)
E499M="e499_kfunc_allowed_caps8 e499_kfunc_allowed_no_query e499_kfunc_allowed_unknown e499_kfunc_syscall_allowed e499_kfunc_syscall_denied e499_kfunc_syscall_reprobe_denied"
TPBM="tpbuf_elf_mismatch tpbuf_elf_no_query tpbuf_elf_ok tpbuf_elf_target_mismatch tpbuf_elf_target_ok tpbuf_elf_unknown tpbuf_elf_unsigned"
E525M="e525_kfunc_raw_tp_allowed e525_kfunc_raw_tp_denied e525_kfunc_raw_tp_no_query e525_kfunc_tracepoint_allowed e525_kfunc_tracepoint_denied" # E045: 機構の5 case。perf_eventは元から問う、key_missingは変異後もprecheck_failed。
V9MECH="$E499M $E525M $PRIVTP $TPBM $V11TP $V9E388 ${V9ATR}v9_ctx_access_no_probe v9_ctx_access_rejected $V9KA v9_mechanism_sched_act_ok v9_mechanism_socket_ok v9_mechanism_syscall_ok v9_ok e631_kstructsize_absent e631_kstructsize_caps15 e631_kstructsize_mix_1032 e631_kstructsize_n1032_1032 e631_kstructsize_n1032_1040 e631_kstructsize_no_query e631_kstructsize_ok e631_kstructsize_smaller e631_kstructsize_unknown " # E060: syscall attach; three precheck errors stay unchanged.
for mf in "check.v9_unknown_blocks:v12_kmulti_no_attach_type_probe v9_attach_target_unknown v9_attach_type_no_probe v9_ctx_access_no_probe " \
          "check.ctx_access_ignored:$V9CTX" \
          "check.mechanism_asks_attach_type:$V9MECH"; do
  gate_context_mutation "${mf%%:*}" "${mf#*:}" "$HERE/build/tools-mut" "$TMPDIR/gate-mut-v9.txt" || die "E031: 変異 ${mf%%:*} の case ID / rc の不一致"
done
nrc=0; BML_MUTANT=parse.v9_rows_any_version "$HERE/scripts/corpus-parse.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-mut-v9p.txt" 2>&1 || nrc=$?
got=$(grep '^DIFF' "$TMPDIR/gate-mut-v9p.txt" | awk '{print $2}' | tr -d : | tr '\n' ' ' || true)
# E039: 版 12 の型 (kprobe_multi・uretprobe_multi (版 8)・usdt) の最小の版も飛ばす
V11P="attach_freplace_before_v11 attach_generic_before_v9 attach_kprobe_multi_before_v12 attach_kretprobe_before_v9 attach_ksyscall_before_v13 attach_trace_lsm_before_v11 attach_trace_lsm_cgroup_before_v13 attach_trace_perf_before_v11 attach_trace_struct_ops_before_v11 attach_trace_tp_before_v11 attach_uretprobe_multi_v8 attach_usdt_before_v12"
[ "$nrc" -eq 1 ] && [ "$got" = "attach_fmodret_before_v10 $V11P ctxaccess_below_min_version e649_netkit_min_version " ] ||
  die "E031: 変異 parse.v9_rows_any_version の落ちる case が予測と違う (rc $nrc): $got"
echo "ok: E031〜E047 の変異 v9_unknown_blocks 4・ctx_access_ignored 20・mechanism_asks_attach_type 46 (E047 の ksyscall の組を含む、E037 の priv_* の 4 と E525 の 5 を含む)・v9_rows_any_version 15 (parse — fmod_ret・版 11 の族・版 12 の型の版の検めも飛ばす)"
. "$HERE/scripts/gate-mutants.sh" # E032〜E041 の版の取り込みの corpus の変異 (500 行の上限で分けた — E041)
# E036 (形式の版 11・判定の版 9 — bpf-mlir E425 / E431): syscalls の event の BPF の ctx の規則・族の型の汎用の照合
nrc=0; BML_MUTANT=check.syscalls_ctx_skip "$HERE/scripts/corpus-cases.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-mut-v11.txt" 2>&1 || nrc=$?
got=$(grep '^DIFF' "$TMPDIR/gate-mut-v11.txt" | awk '{print $2}' | tr -d : | tr '\n' ' ' || true)
[ "$nrc" -eq 1 ] && [ "$got" = "v11_tp_syscalls_not_ctx v17_tp_array_syscall_ctx " ] || die "E036 / E054: 変異 check.syscalls_ctx_skip の落ちる case が予測と違う (rc $nrc): $got"
# check.v11_generic_skip は corpus で落ちない (v11 の case の汎用の答えは全て真) — fixture 4 つ (族ごとに汎用の答えを 1 つ偽に) を Go の ebpf-precheck と比べ、変異で全て ok に
for d in "$HERE"/test/req/fixture/e36/*/; do
  # E037: v1.6.0 の --caps は既定で load の権限 (この process) と probed_as を照らす — fixture は root の記録、--load-as で同じ権限に (check_case は ForLoad しない)
  g36=$("$HERE/build/tools/ebpf-precheck" --loader=cilium-v0.22 --caps="$d/caps.json" --load-as=0:000001ffffffffff --requirements="$d/requirements.txt" | jq -c '{result, unmet: [.unmet[] | del(.detail)]}') || true
  c36=$("$HERE/build/tools/check_case" "$d" | jq -c .)
  [ "$g36" = "$c36" ] && [ "$(jq -r .result <<< "$c36")" = target_rejected ] || die "E036: fixture $(basename "$d") が Go と違う / 止まらない: $c36"
  [ "$(BML_MUTANT=check.v11_generic_skip "$HERE/build/tools-mut/check_case" "$d" | jq -r .result)" = ok ] || die "E036: 変異 check.v11_generic_skip で fixture $(basename "$d") が ok にならない"
done
echo "ok: E036 の変異 syscalls_ctx_skip 2 (E054 の配列を含む)・v11_generic_skip は fixture 4 (Go と同じ target_rejected → ok)"
# E037 (判定の版 10 — bpf-mlir E438): 記録の caps の権限の分離 (ForLoad)
for mf in "caps.priv_ignore_load_as:e499_kfunc_syscall_reprobe_denied priv_differs priv_no_probed_as priv_reprobe_answer_used " \
          "caps.priv_split_all:e499_kfunc_syscall_reprobe_denied priv_reprobe_answer_used priv_reprobe_ok priv_reprobe_record_tpfield "; do
  nrc=0; BML_MUTANT="${mf%%:*}" "$HERE/scripts/corpus-cases.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-mut-v10p.txt" 2>&1 || nrc=$?
  got=$(grep '^DIFF' "$TMPDIR/gate-mut-v10p.txt" | awk '{print $2}' | tr -d : | tr '\n' ' ' || true)
  [ "$nrc" -eq 1 ] && [ "$got" = "${mf#*:}" ] || die "E037: 変異 ${mf%%:*} の落ちる case が予測と違う (rc $nrc): $got"
done
echo "ok: E037 / E042 の変異 priv_ignore_load_as 4・priv_split_all 4 (E042 の kfunc_loads の再 probe の case を含む)"
# E037 (bpf-mlir E441): sk_skb / sk_msg の attach_type の Unmet の文 (sockmap の link) — corpus に無いので fixture 2 つ (host の root の記録の attach_types を偽に) を Go と比べる
for d in "$HERE"/test/req/fixture/e37/*/; do
  for t in ebpf-precheck bml-precheck; do
    "$HERE/build/tools/$t" --loader=cilium-v0.22 --caps="$d/caps.json" --load-as=0:000001ffffffffff --requirements="$d/requirements.txt" > "$TMPDIR/gate-e441-$t.json" || true
  done
  diff <(jq -S 'del(.versions)' "$TMPDIR/gate-e441-ebpf-precheck.json") <(jq -S 'del(.versions)' "$TMPDIR/gate-e441-bml-precheck.json") > /dev/null ||
    die "E037: fixture $(basename "$d") の出力が Go と違う (E441 の文)"
  grep -q 'cannot create a BPF link of that attach type on a sockmap' "$TMPDIR/gate-e441-bml-precheck.json" || die "E037: fixture $(basename "$d") に E441 の文が無い"
done
echo "ok: E037 の E441 の文 (sk_skb・sk_msg) が Go と同じ"

step "E008: DWARF の reader の Go (dwarfParams の複写) との差動・uprobe の照合の bml-precheck と ebpf-precheck の差動 (組 130)・変異 dwarf.no_varparam_skip で Go の binary だけが違う"
if ! verified dwarf_diff; then
  "$HERE/scripts/diff-dwarf.sh" "$HERE/build/tools" || die "E008: DWARF の reader の差動"
  "$HERE/scripts/diff-uprobe-precheck.sh" "$HERE/build/tools" > "$TMPDIR/gate-uprobe-precheck.txt" 2>&1 || { tail -20 "$TMPDIR/gate-uprobe-precheck.txt"; die "E008: uprobe の照合の差動"; }
  tail -1 "$TMPDIR/gate-uprobe-precheck.txt"
  DW="$HERE/build/tmp/diff-dwarf"
  mapfile -t DB < <(grep '^== ' "$DW/c.txt" | cut -c4-)
  BML_MUTANT=dwarf.no_varparam_skip "$HERE/build/tools-mut/dwarf_case" "${DB[@]}" > "$DW/mut.txt" 2>&1
  # diff は違えば 1 (変異は違うのが予測) — rc を取り 1 の時だけ通す (|| true は本当の失敗も飲む — レビュー役の P3)
  drc=0; diff <(awk '/^== /{f=$2} {print f"|"$0}' "$DW/go.txt") <(awk '/^== /{f=$2} {print f"|"$0}' "$DW/mut.txt") > "$DW/mut.diff" || drc=$?
  [ "$drc" -eq 1 ] || die "E008: 変異 dwarf.no_varparam_skip の diff の rc が 1 でない: $drc"
  vf=$(grep '^>' "$DW/mut.diff" | cut -d'|' -f1 | cut -c3- | xargs -r -n1 basename | sort -u | tr '\n' ' ')
  [ "$vf" = "dwarf-oracle ebpf-precheck gofixture " ] || die "E008: 変異 dwarf.no_varparam_skip の違う binary が Go の 3 つでない: $vf"
  echo "ok: 変異 no_varparam_skip は $vf"
  vrecord dwarf_diff
fi

step "E002: bml-precheck と ebpf-precheck — ELF の sweep (記録を共有) と引数の扱い"
if ! verified sweep; then
  "$HERE/scripts/sweep-precheck.sh" 11 "$HERE/build/tools"
  cp "$HERE/build/tools/ebpf-precheck" "$HERE/build/tools-asan/"
  "$HERE/scripts/sweep-precheck.sh" 12 "$HERE/build/tools-asan"
  vrecord sweep
fi
"$HERE/scripts/diff-cli.sh" "$HERE/build/tools"

step "E003: maps の corpus (§12 — release・ASan + UBSan)"
"$HERE/scripts/corpus-maps.sh" "$HERE/build/tools"
"$HERE/scripts/corpus-maps.sh" "$HERE/build/tools-asan"

step "E003: 変異の対照 — maps.always_bidirectional で undeclared_partial だけが落ちる"
if BML_MUTANT=maps.always_bidirectional "$HERE/scripts/corpus-maps.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-mut3.txt" 2>&1; then
  die "変異 maps.always_bidirectional で corpus-maps が落ちない — harness が効いていない"
fi
[ "$(grep '^DIFF' "$TMPDIR/gate-mut3.txt" | awk '{print $2}' | tr -d ':' | tr '\n' ' ')" = "undeclared_partial " ] ||
  die "変異が予測の case (undeclared_partial) でない: $(grep '^DIFF' "$TMPDIR/gate-mut3.txt" | head -3)"
echo "ok: undeclared_partial"

step "E308 (v0.15.0) / E313 (v0.17.0): maps の変異の対照 — maps.globals_empty_is_nil で globals_empty だけ・maps.globals_always_bidirectional で globals_undeclared_allowed だけ・maps.flags_omit_unchecked で flags_unset だけが落ちる"
for mc in maps.globals_empty_is_nil:globals_empty maps.globals_always_bidirectional:globals_undeclared_allowed maps.flags_omit_unchecked:flags_unset "maps.kptr_as_pointer:rec_kptr_as_integer rec_kptr_match rec_kptr_member_omitted rec_kptr_target"; do
  if BML_MUTANT=${mc%%:*} "$HERE/scripts/corpus-maps.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-mutg.txt" 2>&1; then
    die "変異 ${mc%%:*} で corpus-maps が落ちない"
  fi
  [ "$(grep '^DIFF' "$TMPDIR/gate-mutg.txt" | awk '{print $2}' | tr -d ':' | tr '\n' ' ')" = "${mc#*:} " ] ||
    die "変異 ${mc%%:*} が予測の case (${mc#*:}) でない: $(grep '^DIFF' "$TMPDIR/gate-mutg.txt" | head -3)"
done
echo "ok"

step "E003: --maps の sweep (宣言の変異 — declgen) と壊れた BTF の差動 (Go の panic は名指しの既知の差)"
# E011 H2 (b): globals の変異の sweep 4 つ (DECLGEN_GMUT) は外した — 同じ失敗の形を corpus-maps の globals の 10 case・seed 13 の sweep の globals・
# 変異の対照 maps.globals_* が捕まえる (13 の全ての変異の差動は E003 の追記の記録 — 手で `SWEEP_MAPS=1 DECLGEN_GMUT=<n> scripts/sweep-precheck.sh 13`)
if ! verified maps_sweep; then
  SWEEP_MAPS=1 "$HERE/scripts/sweep-precheck.sh" 13 "$HERE/build/tools"
  "$HERE/scripts/diff-btf-records.sh" 5 10 "$HERE/build/tools"
  vrecord maps_sweep
fi

step "E004: kernel の BTF の reader を cilium の btf と差動 (この kernel の vmlinux・種・変異 — c_load_strict は名指しの既知の差)"
if ! verified kbtf; then
  "$HERE/scripts/diff-kbtf.sh" 3 10 "$HERE/build/tools"
  "$HERE/scripts/diff-kbtf.sh" 4 3 "$HERE/build/tools-asan"
  "$HERE/scripts/diff-live-btf.sh" "$HERE/build/tools"
  "$HERE/scripts/diff-live-btf.sh" "$HERE/build/tools-asan"
  vrecord kbtf
fi

step "E022: kernel の BTF の名前の索引 — 鍵の前計算の索引が前の索引 (試験の build の reference) と byte で同じ (ASan + UBSan)、変異 kbtf.index_full_name で比べが落ちる"
"$HERE/build/tools-asan/kbtf_index" 3 || die "E022: 索引が前の索引と違う"
rc=0; BML_MUTANT=kbtf.index_full_name "$HERE/build/tools-mut/kbtf_index" 3 > "$TMPDIR/gate-kbtf-index-mut.txt" 2>&1 || rc=$?
[ "$rc" = 1 ] && grep -q ' same no ' "$TMPDIR/gate-kbtf-index-mut.txt" || { cat "$TMPDIR/gate-kbtf-index-mut.txt"; die "E022: 変異 kbtf.index_full_name が比べで落ちない (rc $rc)"; }

step "E018 (bpf-mlir E326): 作った BTF (循環・共有・自己参照) の kfields の C と Go の差動、変異 live.no_member_seen は循環で終わらない (timeout)"
"$HERE/scripts/diff-kfield-cycle.sh" "$HERE/build/tools"
"$HERE/scripts/diff-kfield-cycle.sh" "$HERE/build/tools-asan"
KC="$HERE/build/tmp/diff-kfield-cycle"
mrc=0; BML_MUTANT=live.no_member_seen BML_TEST_VMLINUX="$KC/cycle.btf" timeout 10 "$HERE/build/tools-mut/live_case" "$KC/q" > /dev/null 2>&1 || mrc=$?
[ "$mrc" -eq 124 ] || die "変異 live.no_member_seen の rc が 124 (timeout) でない: $mrc"
echo "ok: 変異 live.no_member_seen は timeout"

fi # --vm-root で飛ばす非 root の検証の段の終わり (E068)
step "E004: live の差動 (host の kernel — root と bpf+net_admin、sudo — 利用者の承認 2026-09-27) と process の状態"
[ "$GATE_MODE" != vm-root ] || ! vm_needs_elf_list || { "$HERE/scripts/live-elfs.sh" "$TMPDIR/gate-live-elfs.txt" > /dev/null; printf 'live-elfs\t%s\n' "$(sha256sum < "$TMPDIR/gate-live-elfs.txt" | cut -c1-64)" >> "$TMPDIR/inputs.tsv"; } # E068 H3a: e004 を飛ばしても e005・e033・e043 の入力は run の中で新しく
if gate_root e004-live; then
sudo -n true 2> /dev/null || die "E004 の live の差動に sudo -n が要る (root の probe — 飛ばさない)"
"$HERE/scripts/live-elfs.sh" "$TMPDIR/gate-live-elfs.txt" > /dev/null
rsudo "$HERE/scripts/live-diff.sh" "$TMPDIR/gate-live-elfs.txt" "$TMPDIR/gate-live" "$HERE/build/tools" root bpf,net_admin > "$TMPDIR/gate-live.txt" 2>&1
cat "$TMPDIR/gate-live.txt"
n=$(wc -l < "$TMPDIR/gate-live-elfs.txt")
[ "$(grep -c "(A) 記録: *$n same" "$TMPDIR/gate-live.txt")" = 2 ] && [ "$(grep -cE "\(B\) .*: *$n same" "$TMPDIR/gate-live.txt")" = 4 ] || die "live の差動で差"
"$HERE/scripts/live-matrix.sh" "$TMPDIR/gate-live-matrix" > /dev/null
rsudo "$HERE/scripts/live-diff.sh" "$TMPDIR/gate-live-matrix/list.txt" "$TMPDIR/gate-live-mx" "$HERE/build/tools" root bpf,net_admin > "$TMPDIR/gate-live-mx.txt" 2>&1
nm_=$(wc -l < "$TMPDIR/gate-live-matrix/list.txt")
[ "$(grep -c "(A) 記録: *$nm_ same" "$TMPDIR/gate-live-mx.txt")" = 2 ] && [ "$(grep -cE "\(B\) .*: *$nm_ same" "$TMPDIR/gate-live-mx.txt")" = 4 ] || die "live の型の表で差"
echo "ok: 型の表 $nm_"
rsudo "$HERE/scripts/live-state.sh" "$TMPDIR/gate-live-elfs.txt" "$HERE/build/tools" "$TMPDIR/gate-live-state" || die "live の probe が process の状態を変えた / fd を残した"
step "E004: 変異の対照 — live.prog_eperm_true で bpf+net_admin の記録だけが落ちる・live.name_first_match で diff-live-btf が落ちる"
rsudo env BML_MUTANT=live.prog_eperm_true "$HERE/scripts/live-diff.sh" "$TMPDIR/gate-live-elfs.txt" "$TMPDIR/gate-live-mut" "$HERE/build/tools-mut" root bpf,net_admin > "$TMPDIR/gate-live-mut.txt" 2>&1
grep -q "(A) 記録: *$n same" "$TMPDIR/gate-live-mut.txt" && grep -qE "\(A\) 記録: *[0-9]+ diff" "$TMPDIR/gate-live-mut.txt" || die "live.prog_eperm_true が予測の形で落ちない"
fi
if BML_MUTANT=live.name_first_match "$HERE/scripts/diff-live-btf.sh" "$HERE/build/tools-mut" > "$TMPDIR/gate-live-mut2.txt" 2>&1; then die "live.name_first_match で diff-live-btf が落ちない"; fi
echo "ok"

step "E005: libbpf の source の固定 (guard の前提) と guard 付きの load (host の root — sudo) と負の対照"
"$HERE/scripts/libbpf-pin.sh" --check
# E019: guard の section_defs の写し (src/load/secdefs.c) と libbpf の source の表 (順・名前・SEC_EXP_ATTACH_OPT の有無) が同じ
diff <("$HERE/scripts/libbpf-secdefs.sh") <("$HERE/build/tools/load_case" --secdefs) > /dev/null || die "E019: libbpf の section_defs の写しが libbpf の source と違う"
echo "ok: section_defs の写し $("$HERE/build/tools/load_case" --secdefs | wc -l) 行"
if gate_root e005-load; then
rsudo "$HERE/build/tools/load_case" $(cat "$TMPDIR/gate-live-elfs.txt") > "$TMPDIR/gate-load.txt" 2> /dev/null
nl_=$(wc -l < "$TMPDIR/gate-load.txt")
[ "$nl_" = "$(wc -l < "$TMPDIR/gate-live-elfs.txt")" ] || die "load の sweep の件数が合わない"
# guard の停止は E114 の dm_redirect の map_btf (M1 — 型付きの devmap) と、壊れた .BTF の corpus の 3 (E304 — shape: guard が BTF を読めない) だけ。他の段は ok・libbpf (verifier の loud な拒否)・照合で止めた (-)
# E032 の名指しの残り (波 1 の section の shape の停止 33) は E033 で guard の表を広げて外した
stops=$(awk -F'\t' '$3!="ok" && $3!="-" && $3!="libbpf" {print $3" "$1}' "$TMPDIR/gate-load.txt")
M="$HERE/third_party/bpf-mlir/conformance/requirements/maps"
# E036 (v1.5.0): tree の波 2〜4 の ELF の 50 は guard の表に無い section (cgroup/*・lsm/*・tracepoint/*・perf_event・struct_ops・freplace/* 等) で shape —
# 名指しの残り (test/load/fixture/e36_shape_stops.txt — 表を広げるのは後の E、E032 → E033 の形)。E037 (v1.6.0) の E439 の 6.12 の lsm の 4 を足して 54、
# E039 (v1.7.0) の 15 (lsm 5・cgroup 2・kprobe.multi 2 と map-in-map の outer の values の 6 — guard は map-in-map の定義を読まない) を足して 69、E040 で guard の表に tracepoint/ を足し tracepoint の 7 を外して 62、
# E041 (v1.8.0) の 36 (sk_reuseport 8・sk_skb 5・sk_msg 5・kprobe.session 4・sockops 3・kprobe.multi 2・lsm.s 2・lwt_seg6local 2・ksyscall 1 と kfunc の extern の symbol の 4) を足して 98、
# E042 (E499) で 105 (struct_ops 3・raw_tp.w 1・kfunc の extern 3 の 7 — 同じ中身の ELF の代表の path が corpus の写しに替わった 3 も直した)、
# E043 で guard の表に波 2〜4 の 32 の形を足し 72 を外して 33 (残りは freplace・struct_ops・multi / session / ksyscall・kfunc の extern・map-in-map の values)。E045 で新しい shape 26 (E525 10・E508 9・E509 7) を名指しへ追加して 59。
want_stops=$( { printf '%s\n' "shape $M/rec_btf_range_outside/object.bpf.o" "shape $M/rec_btf_record_cut/object.bpf.o" "shape $M/rec_btf_string_no_nul/object.bpf.o" "map_btf $HERE/third_party/bpf-mlir/docs/experiments/results/E114/elf/dm_redirect.bpf.o"
  sed "s|^|shape $HERE/third_party/bpf-mlir/|" "$HERE/test/load/fixture/e36_shape_stops.txt"; awk -F'\t' -v base="$HERE/third_party/bpf-mlir/" '{print $1" "base$2}' "$HERE/test/load/fixture/e062_guard_stops.tsv"; awk -F'\t' -v base="$HERE/third_party/bpf-mlir/" 'FNR==NR{l[$1]=$3"\t"$4;next}{k=base$2;print $1" "k;if(l[k]!=$1"\t"$3)print "reason-mismatch "k}' "$TMPDIR/gate-load.txt" "$HERE/test/load/fixture/e068_guard_stops.tsv"; } | LC_ALL=C sort)
[ "$(LC_ALL=C sort <<< "$stops")" = "$want_stops" ] || die "guard の停止が予測と違う: $stops"
echo "ok: load $nl_ ($(awk -F'\t' '{print $3}' "$TMPDIR/gate-load.txt" | sort | uniq -c | tr '\n' ' '))"
rsudo "$HERE/scripts/load-controls.sh" "$HERE/build/tools" "$HERE/build/tools-mut" || die "guard の負の対照"
rsudo "$HERE/scripts/live-state.sh" "$TMPDIR/gate-live-elfs.txt" "$HERE/build/tools" "$TMPDIR/gate-load-state" load || die "guard 付きの load が process の状態を変えた / fd を残した"
fi

# 波 1 の段 (E033 の guard の section・E034 の test run・E035 の attach — cilium との差動) — 500 行の上限で分けた (E035)
. "$HERE/scripts/gate-wave1.sh"

step "E006 / E007: C ABI の契約の試験 (spinel の面 + E007 の H4 — host の root、unshare -n の中、sudo — 利用者の承認 2026-09-27) と製品の libbml.a に試験の caps が無い"
if nm "$HERE/build/libs/lib/libbml.a" 2>/dev/null | grep -E ' (deny_helper|deny_type|unknown_helper)$' > /dev/null || grep -qa 'bml_test: helper probe' "$HERE/build/libs/lib/libbml.a"; then
  die "libbml.a に試験の caps (BML_TEST_CAPS)"
fi
if gate_root e006-abi; then
FL="$HERE/third_party/bpf-mlir/kernel/flow/mlir"
mkdir -p "$TMPDIR/abi"
"$HERE/build/bpf-mlir/bin/ebpf-compile" "$FL/flow.mlir" --schema "$FL/schema.json" -o "$TMPDIR/abi/flow.bpf.o"
PCF="$HERE/test/shim/fixture"
"$HERE/build/bpf-mlir/bin/ebpf-compile" "$PCF/percpu.mlir" --schema "$PCF/percpu.schema.json" -o "$TMPDIR/abi/percpu.bpf.o"
BG="$HERE/third_party/bpf-mlir/docs/experiments/results/E075/bg.bpf.o"
GLM="$HERE/third_party/bpf-mlir/kernel/globals/mlir"
"$HERE/build/bpf-mlir/bin/ebpf-compile" "$GLM/multi.mlir" --schema "$GLM/schema.json" -o "$TMPDIR/abi/multi.bpf.o"
BGS=$(/opt/llvm-23.1.1/bin/llvm-objcopy --dump-section .ebpf_requirements="$TMPDIR/abi/bg.req" "$BG" "$TMPDIR/abi/bg.tmp.o" && awk -F'\t' '$1=="schema"{print $3}' "$TMPDIR/abi/bg.req")
rsudo "$HERE/scripts/abi-target.sh" "$TMPDIR/abi/flow.bpf.o" "$(sha256sum "$FL/schema.json" | cut -d' ' -f1)" "$TMPDIR/gate-abi" \
  "$HERE/build/tools-asan" "$HERE/build/tools-mut" "$BG" "$BGS" "$TMPDIR/abi/percpu.bpf.o" "$(sha256sum "$PCF/percpu.schema.json" | cut -d' ' -f1)" \
  "$TMPDIR/abi/multi.bpf.o" "$(sha256sum "$GLM/schema.json" | cut -d' ' -f1)" \
  > "$TMPDIR/gate-abi.txt" 2>&1 || { cat "$TMPDIR/gate-abi.txt"; die "E006 / E007 の契約の試験"; }
grep -q ': ok 80$' "$TMPDIR/gate-abi.txt" || { cat "$TMPDIR/gate-abi.txt"; die "E006 / E007 の ok が 80 (48 + H4 の 16 + globals の 13 + close の競合の 3) でない"; }
cat "$TMPDIR/gate-abi.txt"
fi

step "E012〜: mojo の面の群 (scripts/abi-mojo.tsv — trace・tcx …) の契約 (ASan と sanitizer 無し)・変異の対照 (host の root、unshare -n の中、sudo — 利用者の承認 2026-09-28)、Go の loader (mojo の試験の c-archive) との差動は verified の鍵"
if gate_root e012-mojo; then
MGROUPS=$(awk -F'\t' '!/^#/{print $1}' "$HERE/scripts/abi-mojo.tsv")
MDRV=""
if ! verified abi_mojo_diff; then
  # shellcheck disable=SC2086
  "$HERE/scripts/mojo-oracle.sh" > /dev/null && "$HERE/scripts/abi-mojo-diff.sh" build $MGROUPS || die "mojo の面の差動の driver の build"
  MDRV="$HERE/build/tmp/abi-mojo/drv"
fi
for g in $MGROUPS; do
  IFS=$'\t' read -r _ _ fxs okn muts _ < <(awk -F'\t' -v g="$g" '$1==g' "$HERE/scripts/abi-mojo.tsv")
  # fixture は "," の列 (E015 — 先頭が群の ELF、他は道具の追加の引数の ELF)
  for f in ${fxs//,/ }; do
    "$HERE/build/bpf-mlir/bin/ebpf-compile" "$HERE/test/abi/fixture/$f.mlir" --schema "$HERE/test/abi/fixture/$f.schema.json" -o "$TMPDIR/abi/$f.bpf.o"
  done
  fx=${fxs%%,*}
  rsudo "$HERE/scripts/abi-mojo-target.sh" "$g" "$TMPDIR/abi/$fx.bpf.o" "$(sha256sum "$HERE/test/abi/fixture/$fx.schema.json" | cut -d' ' -f1)" \
    "$TMPDIR/gate-mojo" "$HERE/build/tools-asan" "$HERE/build/tools-mut" $MDRV > "$TMPDIR/gate-mojo-$g.txt" 2>&1 || { cat "$TMPDIR/gate-mojo-$g.txt"; die "群 $g の契約の試験"; }
  TD="$TMPDIR/gate-mojo/$(uname -r)/$g"
  grep -q ": ok $okn、FAIL 0$" "$TMPDIR/gate-mojo-$g.txt" || { cat "$TMPDIR/gate-mojo-$g.txt"; die "群 $g の ok が $okn でない"; }
  # 変異の対照: 意図した理由で落ちる (FAIL の id の組が表と同じ)
  IFS=';' read -ra ms <<< "$muts"
  for mf in "${ms[@]}"; do
    got=$(grep ' — FAIL$' "$TD/mut-${mf%%:*}.txt" | cut -d: -f1 | tr '\n' ' ')
    [ "$got" = "${mf#*:} " ] || die "群 $g の変異 ${mf%%:*} の FAIL が「${mf#*:}」でない: 「$got」"
  done
  [ -z "$MDRV" ] || "$HERE/scripts/abi-mojo-diff.sh" compare "$g" "$TD" || die "群 $g の Go の loader との差動"
  cat "$TMPDIR/gate-mojo-$g.txt"
done
[ -z "$MDRV" ] || vrecord abi_mojo_diff
fi

step "E019: 権限の組 (root・bpf+net_admin・bpf+perfmon・none) × 種類 (fentry・fexit・kprobe・xdp) の load の kind と権限の hint を bml と mojo の Go で (host、sudo — 利用者の承認 2026-09-28)"
if gate_root e019-capload && ! verified capload; then
  "$HERE/scripts/mojo-oracle.sh" > /dev/null && "$HERE/scripts/abi-mojo-diff.sh" build capload > /dev/null || die "E019 の driver の build"
  mkdir -p "$TMPDIR/e019"
  for f in fe fx kp xp; do
    "$HERE/build/bpf-mlir/bin/ebpf-compile" "$HERE/test/abi/fixture/e19$f.mlir" --schema "$HERE/test/abi/fixture/e19$f.schema.json" -o "$TMPDIR/e019/e19$f.bpf.o"
    sha256sum "$HERE/test/abi/fixture/e19$f.schema.json" | cut -d' ' -f1 > "$TMPDIR/e019/e19$f.sha"
  done
  rsudo "$HERE/scripts/capload-target.sh" "$TMPDIR/gate-capload" "$HERE/build/tmp/abi-mojo/drv" "$TMPDIR/e019" || die "E019: 権限の組の load の表が mojo の Go と違う"
  grep -qx 'bpf,perfmon/fe kind=0 hint=no perfmon=no net_admin=no' "$TMPDIR/gate-capload/$(uname -r)/bml.txt" || die "E019: {bpf, perfmon} の fentry が load できない (退行)"
  vrecord capload
fi

step "E024: 群 6 (tp_btf) — 契約 (ASan)・変異の対照・権限の組 × e24tc / e24tp の load を mojo の Go と・照合しない load の attach と実の trigger (fork) を cilium の AttachTracing と (host、unshare -n、sudo — 利用者の承認 2026-09-28)"
if gate_root e024-tpbtf && ! verified tpbtf; then
  "$HERE/scripts/mojo-oracle.sh" > /dev/null && "$HERE/scripts/abi-mojo-diff.sh" build capload > /dev/null || die "E024 の capload の driver の build"
  "$HERE/scripts/build-oracles.sh" > /dev/null || die "E024 の Go の oracle の build"
  mkdir -p "$TMPDIR/e024"
  for f in tc tp; do
    "$HERE/build/bpf-mlir/bin/ebpf-compile" "$HERE/test/abi/fixture/e24$f.mlir" --schema "$HERE/test/abi/fixture/e24$f.schema.json" -o "$TMPDIR/e024/e24$f.bpf.o"
    sha256sum "$HERE/test/abi/fixture/e24$f.schema.json" | cut -d' ' -f1 > "$TMPDIR/e024/e24$f.sha"
  done
  rsudo "$HERE/scripts/tpbtf-target.sh" "$TMPDIR/gate-tpbtf" "$HERE/build/tools-asan" "$HERE/build/tools-mut" "$HERE/build/tmp/abi-mojo/drv" \
    "$HERE/build/oracles/tpbtf-oracle" "$TMPDIR/e024" > "$TMPDIR/gate-tpbtf.txt" 2>&1 || { cat "$TMPDIR/gate-tpbtf.txt"; die "E024: 群 6 の試験"; }
  grep -E '^mut |tpbtf-target|^abi_tpbtf:' "$TMPDIR/gate-tpbtf.txt"
  vrecord tpbtf
fi

step "E025: libbpf の print — object の間の attach の warning が呼び手の stderr にも callback にも出ず、close の後は呼び手の print に戻る (host、unshare -n、sudo — 利用者の承認 2026-09-28)、変異 load.print_passthrough (Q1 Q3)・load.print_no_restore (Q2 Q4)"
mkdir -p "$TMPDIR/e025"
"$HERE/build/bpf-mlir/bin/ebpf-compile" "$HERE/test/abi/fixture/e25kp.mlir" --schema "$HERE/test/abi/fixture/e25kp.schema.json" -o "$TMPDIR/e025/e25kp.bpf.o"
e25sha=$(sha256sum "$HERE/test/abi/fixture/e25kp.schema.json" | cut -d' ' -f1)
if gate_root e025-print; then
rsudo unshare -n "$HERE/build/tools-asan/abi_print" "$TMPDIR/e025/e25kp.bpf.o" "$e25sha" > "$TMPDIR/gate-print.txt" 2>&1 || { cat "$TMPDIR/gate-print.txt"; die "E025: libbpf の print の試験"; }
grep -q '^abi_print: ok 4, FAIL 0$' "$TMPDIR/gate-print.txt" || { cat "$TMPDIR/gate-print.txt"; die "E025: ok が 4 でない"; }
for mf in "load.print_passthrough:Q1 Q3" "load.print_no_restore:Q2 Q4"; do
  rc=0; rsudo BML_MUTANT="${mf%%:*}" unshare -n "$HERE/build/tools-mut/abi_print" "$TMPDIR/e025/e25kp.bpf.o" "$e25sha" > "$TMPDIR/gate-print-mut.txt" 2>&1 || rc=$?
  got=$(grep -E '^Q[0-9]+: .* — FAIL$' "$TMPDIR/gate-print-mut.txt" | cut -d: -f1 | tr '\n' ' ' || true)
  [ "$rc" = 1 ] && [ "$got" = "${mf#*:} " ] || { cat "$TMPDIR/gate-print-mut.txt"; die "E025: 変異 ${mf%%:*} の FAIL が「${mf#*:}」でない: 「$got」(rc $rc)"; }
done
echo "ok: abi_print 4 / 変異 load.print_passthrough (Q1 Q3)・load.print_no_restore (Q2 Q4)"
fi

step "E026: libbpf の print の借りを bml_obj の数で — 重なる 2 つの object の 1 つ目の close の後も漏れない・最後の close で戻る・同時の load の log が thread ごと (host、unshare -n、sudo — E025 の範囲)、変異 4 つ (K3 は race — 決まった形は正規表現で、shared_log は 3 回まで)"
if gate_root e026-holder; then
rsudo unshare -n "$HERE/build/tools-asan/print_hold" "$TMPDIR/e025/e25kp.bpf.o" > "$TMPDIR/gate-hold.txt" 2>&1 || { cat "$TMPDIR/gate-hold.txt"; die "E026: print の借りの試験"; }
grep -q '^print_hold: ok 4, FAIL 0$' "$TMPDIR/gate-hold.txt" || { cat "$TMPDIR/gate-hold.txt"; die "E026: ok が 4 でない"; }
for mf in "load.print_no_restore:^K2 K4 $:1" "load.print_passthrough:^K1 (K3 )?$:1" "load.print_restore_each_close:^K1 (K3 )?$:1" "load.print_shared_log:^K3 $:3"; do
  m=${mf%%:*}; rest=${mf#*:}; re=${rest%:*}; tries=${rest##*:}; ok=0
  for _ in $(seq "$tries"); do
    rc=0; rsudo BML_MUTANT="$m" unshare -n "$HERE/build/tools-mut/print_hold" "$TMPDIR/e025/e25kp.bpf.o" > "$TMPDIR/gate-hold-mut.txt" 2>&1 || rc=$?
    got=$(grep -E '^K[0-9]+: .* — FAIL$' "$TMPDIR/gate-hold-mut.txt" | cut -d: -f1 | tr '\n' ' ' || true)
    if [ "$rc" = 1 ] && [[ "$got" =~ $re ]]; then ok=1; break; fi
    # shared_log の race は多くが K3 の同時の load の中の crash (1 つの buffer への同時の書きと解放の後の書き — 変異が入れる誤りそのもの。
    # E027 の前の gate で 4 × 30 の 10 回中 9 回が SIGABRT、1 回が K3 の FAIL): K1・K2 が ok で K3 の行の前に signal で終わった形も受ける
    if [ "$m" = load.print_shared_log ] && { [ "$rc" = 134 ] || [ "$rc" = 139 ]; } && [ -z "$got" ] &&
       [ "$(grep -cE '^K[12]: .* — ok$' "$TMPDIR/gate-hold-mut.txt")" = 2 ] && ! grep -q '^K3:' "$TMPDIR/gate-hold-mut.txt"; then
      ok=1; got="(K3 の中の crash rc $rc)"; break
    fi
  done
  [ "$ok" = 1 ] || { cat "$TMPDIR/gate-hold-mut.txt"; die "E026: 変異 $m の FAIL「$got」が $re でない ($tries 回)"; }
  echo "ok: 変異 $m — FAIL $got"
done
fi

. "$HERE/scripts/gate-fuzz.sh"

step "submodule が汚れていない"
for s in bpf-mlir libbpf elfutils zlib; do
  [ -z "$(git -C "$HERE/third_party/$s" status --porcelain)" ] || die "third_party/$s が汚れた"
done
echo "ok"

printf '   [%ds]\n' $((SECONDS - _gate_t))
gate_mode_finish "$SECONDS"
