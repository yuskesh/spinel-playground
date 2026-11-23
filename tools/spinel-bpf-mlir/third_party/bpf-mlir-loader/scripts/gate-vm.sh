# scripts/gate-vm.sh — gate.sh の rsudo と --vm-root の転送 (E068)。gate-mode.sh から読む。単独で走らせない。
# --vm-root: 段の本体と判定は host の gate.sh のまま、rsudo だけを rw の共有の queue から VM の guest に渡す (host の通常 user、sudo に落ちない)。
# 契約 (E068 H2): 応答は run と job の id と実 argv・cwd・env の hash に結び付き、完了の dir の rename の後だけ読む。
# 転送や保存の故障は対象の command の rc にしない — FATAL を残して gate の main を止める (pipeline・$(...)・|| true の中でも。rc 75)。
GATE_VM_STAGES=(e005-load e033-wave1-load e043-wave24-load e034-wave1-run e035-wave1-attach e038-caller-attach
  e040-tpallcpu e044-usdt e049-ksyscall e051-netfilter e053-strarg e054-tparray e055-splitdwarf e056-uprobe-offset
  e006-abi e012-mojo e019-capload e024-tpbtf e025-print e026-holder)
GATE_VM_FATAL_RC=75
# sudo calls that load / attach BPF as root run one at a time inside bpf-mlir's host-wide lock (at the bpf-mlir coordinator's request, 2026-10-04 — bpf-mlir's root stages
# compare the whole host's bpftool output before and after; the same file as scripts/root-stage.sh). It is held only during a call, not during the non-root build or comparison (1ed781c
# held it for the whole stage and stopped bpf-mlir's root stage for 12 minutes). The fd is opened and closed in a subshell per call (the gate's shell holds no fd — so a failure or a signal midway
# leaves no lock, as the bpf-mlir coordinator advised). flock works on a read fd too. Without the file it stops (bpf-mlir's side creates it — never silently), and after 30 minutes without the lock it is an error
RL=${GATE_ROOT_LOCK:-/run/lock/bpf-mlir-root.lock}
rsudo() { [ "$GATE_MODE" != static ] || die 'unexpected-root: rsudo reached in --static'
  if [ "$GATE_MODE" = vm-root ]; then vm_rsudo "$@"; return $?; fi
  [ -e "$RL" ] || die "bpf-mlir の root の lock $RL が無い (bpf-mlir の root の段が作る)"
  ( flock -n 9 || { echo "gate: bpf-mlir の root の lock を他が持つ — 待つ" >&2; flock -w 1800 9; } || { echo "gate: root の lock を 30 分取れない" >&2; exit 125; }
    sudo -n "$@" ) 9< "$RL"; }

vm_init() {
  local s
  [ "$(id -u)" != 0 ] || { echo 'gate: --vm-root は host の通常 user で (euid 0 は拒否)' >&2; return 64; }
  [ -z "${VERIFIED_RECORD:-}" ] || { echo 'gate: --vm-root conflicts with VERIFIED_RECORD' >&2; return 64; }
  [ -d "${GATE_VM_OUT:-}" ] || { echo 'gate: --vm-root には GATE_VM_OUT (rw の共有の dir) が要る' >&2; return 64; }
  [[ "${GATE_VM_RUN_ID:-}" =~ ^[0-9a-f]{16}$ ]] || { echo 'gate: --vm-root には GATE_VM_RUN_ID (16 桁の hex) が要る' >&2; return 64; }
  [[ "${GATE_VM_LABEL:-}" =~ ^[a-z0-9-]+$ ]] || { echo 'gate: --vm-root には GATE_VM_LABEL が要る' >&2; return 64; }
  GATE_VM_Q="$GATE_VM_OUT/queue"
  [ -d "$GATE_VM_Q/req" ] && [ -d "$GATE_VM_Q/resp" ] && [ "$(cat "$GATE_VM_Q/run-id" 2>/dev/null)" = "$GATE_VM_RUN_ID" ] ||
    { echo 'gate: --vm-root の queue が無いか run id が違う' >&2; return 64; }
  local only=${GATE_VM_ONLY:-}
  for s in ${only//,/ }; do
    [[ " ${GATE_VM_STAGES[*]} " == *" $s "* ]] || { echo "gate: GATE_VM_ONLY の段が 20 段に無い: $s" >&2; return 64; }
  done
  GATE_VM_TMP="$GATE_VM_OUT/tmp-$GATE_VM_LABEL"
  mkdir "$GATE_VM_TMP" 2>/dev/null || { echo "gate: 出力の dir が既に在る: $GATE_VM_TMP" >&2; return 64; }
  GATE_VM_LEDGER="$GATE_VM_TMP/ledger.tsv"; : > "$GATE_VM_LEDGER"
  GATE_VM_MAIN=$$ GATE_VM_CUR='' GATE_VM_JOB_LIMIT=${GATE_VM_JOB_LIMIT:-1500}
  GATE_FULL=1
  trap "exit $GATE_VM_FATAL_RC" TERM
  trap vm_on_exit EXIT
}
vm_on_exit() { [ ! -e "$GATE_VM_Q/FATAL" ] || exit "$GATE_VM_FATAL_RC"; }
vm_fatal() {
  printf '%s\n' "$*" >> "$GATE_VM_Q/FATAL"
  echo "gate: VM-TRANSPORT-FATAL: $*" >&2
  kill -TERM "$GATE_VM_MAIN" 2>/dev/null
  exit "$GATE_VM_FATAL_RC"
}
vm_selected() { # 段が選ばれているか (e004-live と GATE_VM_ONLY の外は偽)
  [[ " ${GATE_VM_STAGES[*]} " == *" $1 "* ]] || return 1
  [ -z "${GATE_VM_ONLY:-}" ] || [[ ",$GATE_VM_ONLY," == *",$1,"* ]]
}
vm_needs_elf_list() { vm_selected e005-load || vm_selected e033-wave1-load || vm_selected e043-wave24-load; } # gate-live-elfs.txt の消費者
vm_jobs_so_far() { cat "$GATE_VM_Q/counter" 2>/dev/null || echo 0; }
vm_stage_close() {
  [ "$GATE_MODE" = vm-root ] && [ -n "${GATE_VM_CUR:-}" ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\tclosed\n' "$GATE_VM_CUR" "$GATE_VM_CUR_J" "$(vm_jobs_so_far)" "$GATE_VM_CUR_S" "$(date +%s)" >> "$GATE_VM_LEDGER" || vm_fatal "ledger を書けない"
  GATE_VM_CUR=''
}
vm_stage_begin() {
  vm_stage_close
  ! grep -q "^$1	" "$GATE_VM_LEDGER" || vm_fatal "段が 2 回: $1"
  GATE_VM_CUR=$1 GATE_VM_CUR_J=$(vm_jobs_so_far) GATE_VM_CUR_S=$(date +%s)
}
vm_finish() { # 段の集合が選択と同じ・FATAL が無い
  local want s
  vm_stage_close
  [ ! -e "$GATE_VM_Q/FATAL" ] || vm_fatal "FATAL が在る"
  for s in "${GATE_VM_STAGES[@]}"; do vm_selected "$s" && want+="$s"$'\n'; done
  [ "$(printf '%s' "$want" | LC_ALL=C sort)" = "$(cut -f1 "$GATE_VM_LEDGER" | LC_ALL=C sort)" ] || vm_fatal "台帳の段の集合が選択と違う"
  [ "$(cut -f1 "$GATE_VM_LEDGER" | LC_ALL=C sort | uniq -d | wc -l)" = 0 ] || vm_fatal "台帳に重複"
}
vm_next_job() { ( flock 8 || exit 1; n=$(( $(cat "$GATE_VM_Q/counter" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GATE_VM_Q/counter" || exit 1; printf '%06d' "$n" ) 8>> "$GATE_VM_Q/.counter.lock"; }
vm_sha() { sha256sum "$1" | cut -c1-64; }
vm_meta() { awk -F'\t' -v k="$2" '$1==k{print $2; exit}' "$1"; }
vm_rsudo() {
  local n q r t d i end c rc
  [ "$#" -gt 0 ] || vm_fatal "rsudo の argv が空"
  q=$GATE_VM_Q
  [ ! -e "$q/FATAL" ] || vm_fatal "前の転送の故障の後の job"
  n=$(vm_next_job) || vm_fatal "job の番号を取れない"
  t="$q/req/.$n.tmp"; r="$q/req/$n"; d="$q/resp/$n"
  mkdir "$t" || vm_fatal "job $n: 要求の dir を作れない"
  { printf '%s\0' "$@" > "$t/argv" && printf '%s' "$PWD" > "$t/cwd" &&
    printf '%s\0' HOME=/root PATH=/usr/bin:/usr/sbin:/sbin:/bin "SUDO_UID=$(id -u)" "SUDO_GID=$(id -g)" "SUDO_USER=$(id -un)" "LANG=${LANG:-C.UTF-8}" > "$t/env" &&
    printf 'run\t%s\njob\t%s\nargv\t%s\ncwd\t%s\nenv\t%s\n' "$GATE_VM_RUN_ID" "$n" "$(vm_sha "$t/argv")" "$(vm_sha "$t/cwd")" "$(vm_sha "$t/env")" > "$t/meta" &&
    mv "$t" "$r"; } || vm_fatal "job $n: 要求を保存できない"
  end=$((SECONDS + GATE_VM_JOB_LIMIT))
  while [ ! -d "$d" ]; do
    [ ! -e "$q/guest-exited" ] && [ ! -e "$q/guest-gone" ] || [ -d "$d" ] || vm_fatal "job $n: guest が終わった"
    [ "$SECONDS" -lt "$end" ] || vm_fatal "job $n: 応答が枠の中に来ない (${GATE_VM_JOB_LIMIT} s)"
    sleep 0.02
  done
  for i in meta rc stdout stderr; do [ -f "$d/$i" ] || vm_fatal "job $n: 応答に $i が無い"; done
  [ "$(vm_meta "$d/meta" run)" = "$GATE_VM_RUN_ID" ] || vm_fatal "job $n: 応答の run が違う"
  [ "$(vm_meta "$d/meta" job)" = "$n" ] || vm_fatal "job $n: 応答の job が違う"
  for i in argv cwd env; do [ "$(vm_meta "$d/meta" "$i")" = "$(vm_meta "$r/meta" "$i")" ] || vm_fatal "job $n: 応答の $i の hash が違う"; done
  [ "$(vm_meta "$d/meta" transport)" = ok ] || vm_fatal "job $n: guest の転送の故障: $(vm_meta "$d/meta" transport)"
  rc=$(cat "$d/rc"); [[ "$rc" =~ ^[0-9]+$ ]] && [ "$rc" -le 255 ] && [ "$(vm_meta "$d/meta" rc)" = "$rc" ] || vm_fatal "job $n: 応答の rc が不正"
  for i in stdout stderr; do [ "$(vm_meta "$d/meta" "$i")" = "$(vm_sha "$d/$i")" ] || vm_fatal "job $n: 応答の $i が途中までか壊れている"; done
  [ "$SECONDS" -lt "$end" ] || vm_fatal "job $n: 応答が枠の後に届いた (${GATE_VM_JOB_LIMIT} s)" # 受理の地点でも (host が枠の間止まっていても、遅い応答を成功にしない)
  c=0; cat "$d/stdout" || c=$?; [ "$c" = 0 ] || [ "$c" = 141 ] || vm_fatal "job $n: stdout を渡せない ($c)"
  c=0; cat "$d/stderr" >&2 || c=$?; [ "$c" = 0 ] || vm_fatal "job $n: stderr を渡せない ($c)"
  return "$rc"
}
