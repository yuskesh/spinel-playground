# scripts/lib/guest-only.sh — E165 (利用者の決定 2026-11-10): root の段は VM の guest の中だけ。host では sudo を実行しない。
# source する。`vm_guest_check <cmdline の path>` は /proc/cmdline 相当の file に spinelbpf_vm_mark=<印> (印は env の SPINELBPF_VM_MARK — boot ごとの乱数) が在れば 0。
# `vm_guest_require` は host なら rc 126 で止める (root の script の頭で呼ぶ)。path は引数で渡す (対照は偽物の file を渡す — env では替えない)。
vm_guest_check() {
  local cl=$1 m=${SPINELBPF_VM_MARK:-} f
  [ -n "$m" ] && [ -r "$cl" ] || return 1
  for f in $(cat "$cl"); do [ "$f" = "spinelbpf_vm_mark=$m" ] && return 0; done
  return 1
}
vm_guest_require() {
  vm_guest_check /proc/cmdline || { echo "$0: refusing to run on the host — root stages run only in the VM guest (scripts/gate-vm.sh, E165)" >&2; exit 126; }
}
# vm_record_ok checks the form of a verified record ID (E<digits>) (the formal host and the guest refuse an empty or bad one by the same rule before BPF — the bpf-mlir reviewer).
vm_record_ok() { [[ "${1:-}" =~ ^E[0-9]+$ ]]; }
