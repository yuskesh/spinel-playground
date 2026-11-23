# Real gate mode / root stage selection, also sourced by check-gate-mode.sh.
# Human approval: 2026-11-06, directly in a bpf-mlir implementer's Codex pane.
# Default/full retain root checks; STATIC PASS is only a branch checkpoint.
. "$(dirname "${BASH_SOURCE[0]}")/gate-vm.sh"
gate_mode_init() {
  GATE_MODE=default
  GATE_DEFERRED=()
  case "$#:$*" in
    0:) ;;
    1:--full) GATE_MODE=full; GATE_FULL=1 ;;
    1:--static)
      if [ "${GATE_FULL:-0}" = 1 ] || [ -n "${VERIFIED_RECORD:-}" ]; then
        echo 'gate: --static conflicts with GATE_FULL / VERIFIED_RECORD' >&2; return 64
      fi
      GATE_MODE=static ;;
    1:--vm-root) GATE_MODE=vm-root; vm_init || return $? ;; # E068: rsudo を VM の guest に転送 (host の通常 user だけ)
    *) echo 'gate: usage: gate.sh [--full|--static|--vm-root]' >&2; return 64 ;;
  esac
}
gate_root() {
  case "$1" in
    e004-live|e005-load|e033-wave1-load|e043-wave24-load|e034-wave1-run|\
    e035-wave1-attach|e038-caller-attach|e040-tpallcpu|e044-usdt|e049-ksyscall|\
    e051-netfilter|e053-strarg|e054-tparray|e055-splitdwarf|e056-uprobe-offset|\
    e006-abi|e012-mojo|e019-capload|e024-tpbtf|e025-print|e026-holder) ;;
    *) echo "gate: unknown root stage: $1" >&2; exit 64 ;;
  esac
  if [ "$GATE_MODE" = vm-root ]; then vm_selected "$1" || return 1; vm_stage_begin "$1"; return 0; fi
  [ "$GATE_MODE" = static ] || return 0
  GATE_DEFERRED+=("$1")
  return 1
}
gate_mode_finish() {
  if [ "$GATE_MODE" = vm-root ]; then
    vm_finish
    printf '\n== gate: VM-ROOT PASS (only=%s, jobs=%s, %ds)\n' "${GATE_VM_ONLY:-all}" "$(vm_jobs_so_far)" "$1"
  elif [ "$GATE_MODE" = static ]; then
    printf 'deferred: %s\n' "${GATE_DEFERRED[@]}"
    for stage in "${GATE_DEFERRED[@]}"; do
      [ "$stage" != e025-print ] || printf 'deferred-arm: e025-print/%s\n' \
        abi_print load.print_passthrough load.print_no_restore
    done
    printf '\n== gate: STATIC PASS (non-root only; full/live deferred, %ds)\n' "$1"
  else
    printf '\n== gate: PASS (全体 %ds)\n' "$1"
  fi
}
