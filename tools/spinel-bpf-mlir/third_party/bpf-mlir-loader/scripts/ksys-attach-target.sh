#!/bin/bash
# scripts/ksys-attach-target.sh — E049: ksyscall の attach の root の段 (unshare -n の中 — 呼び手は gate の rsudo か flock の中の sudo)。
# bml (ksys_run — ASan) と Go の livecaps.AttachKsyscall (ksys-attach-oracle) の行を比べ、変異 3 つと製品の照合する load (checked) を見る。
# E052: 製品の口 (product — 照合する load) の行・nosys の照合を Go の ebpf-precheck --live と、宣言の変異 abi.decl_* 3 つ。
# 1 行ずつ結果を書き、予測と違えば rc 1。
#
#   sudo scripts/ksys-attach-target.sh <作業の dir — count / args / nosys の .bpf.o と .sha> <tools-asan> <tools-mut> <ksys-attach-oracle> <ebpf-precheck (Go)>
set -uo pipefail
D="${1:?}"; TA="${2:?}"; TM="${3:?}"; ORA="${4:?}"; PRE="${5:?}"
[ "$(id -u)" = 0 ] || { echo "ksys-attach-target: root で走らせる" >&2; exit 2; }
U=${SUDO_UID:-1000}
bad=0
run() { timeout 60 unshare -n "$@"; }
A=("$D/count.bpf.o" "$(cat "$D/count.sha")" "$D/args.bpf.o" "$(cat "$D/args.sha")" "$D/nosys.bpf.o" "$(cat "$D/nosys.sha")")
run "$ORA" "$D/count.bpf.o" "$D/args.bpf.o" "$D/nosys.bpf.o" > "$D/go.txt" 2> "$D/go.err" || { echo "FAIL go"; bad=1; }
run "$TA/ksys_run" run "${A[@]}" > "$D/c.txt" 2> "$D/c.err" || { echo "FAIL c"; bad=1; }
want=$'target count __x64_sys_getppid\ncount 1000\ntarget args __x64_sys_prctl\nargs 5 0x4e472 0x1111 0x2222 0x3333 0x4444 5\nnosys error\nleft 0'
cmp -s "$D/go.txt" "$D/c.txt" && [ "$(cat "$D/c.txt")" = "$want" ] && echo "same c go" || { echo "DIFF c go"; bad=1; }
# 変異: 照らしが別の関数を捕まえる・付ける前の machine の拒否・照らしを外すと付いてしまう (照らしが唯一の段)
BML_MUTANT=ksys.target_other run "$TM/ksys_run" run "${A[@]}" > /dev/null 2> "$D/m1.err"
grep 'attached to __x64_sys_getpid, not the syscall wrapper __x64_sys_getppid' "$D/m1.err" > /dev/null && echo "mutant ksys.target_other ok" || { echo "BAD target_other"; bad=1; }
BML_MUTANT=ksys.machine_other run "$TM/ksys_run" run "${A[@]}" > /dev/null 2> "$D/m2.err"
grep 'no syscall wrapper prefix is known for the kernel machine "riscv64"' "$D/m2.err" > /dev/null && echo "mutant ksys.machine_other ok" || { echo "BAD machine_other"; bad=1; }
BML_MUTANT=ksys.target_other_unconfirmed run "$TM/ksys_run" run "${A[@]}" > "$D/m3.txt" 2> /dev/null
w3=$'target count __x64_sys_getpid\ncount 0\ntarget args __x64_sys_getpid\nargs 0 0x0 0x0 0x0 0x0 0x0 5\nnosys ok\nleft 0'
[ "$(cat "$D/m3.txt")" = "$w3" ] && echo "mutant ksys.target_other_unconfirmed ok" || { echo "BAD target_other_unconfirmed: $(tr '\n' '|' < "$D/m3.txt")"; bad=1; }
# E052: 製品の照合する load (C ABI の宣言 cilium-v0.22-usdt-ksyscall — ksyscall_attach prefix) は OK (E049 は cilium-v0.22-usdt — ksyscall_loader)
chk() { BML_MUTANT="$1" run "$2/ksys_run" checked "$D/count.bpf.o" "$(cat "$D/count.sha")" 2> /dev/null; }
[ "$(chk "" "$TA")" = 'checked kind=0 unmet=' ] && echo "checked ok" || { echo "BAD checked: $(chk "" "$TA")"; bad=1; }
# E052: 製品の口の取り直し — count / args の行は run と同じ、無い syscall は照合が止める (attach の段から照合の段へ)
run "$TA/ksys_run" product "${A[@]}" > "$D/product.txt" 2> "$D/product.err" || { echo "FAIL product"; bad=1; }
wp=$'target count __x64_sys_getppid\ncount 1000\ntarget args __x64_sys_prctl\nargs 5 0x4e472 0x1111 0x2222 0x3333 0x4444 5\nnosys checked kind=3 unmet=attach\nleft 0'
[ "$(cat "$D/product.txt")" = "$wp" ] && echo "same product" || { echo "DIFF product: $(tr '\n' '|' < "$D/product.txt")"; bad=1; }
# nosys の照合の oracle: Go の ebpf-precheck の live (同じ root・同じ netns の形) の result と unmet の kind の集合
run "$PRE" --loader=cilium-v0.22-usdt-ksyscall --live --schema-sha256="$(cat "$D/nosys.sha")" "$D/nosys.bpf.o" > "$D/nosys-go.json" 2> "$D/nosys-go.err"
gk=$(tr -d '\n' < "$D/nosys-go.json" | grep -o '"result": *"[a-z_]*"\|"kind": *"[a-z_]*"' | sed 's/.*"\([a-z_]*\)"$/\1/' | tr '\n' ' ')
[ "$gk" = "target_rejected attach " ] && echo "same nosys go" || { echo "DIFF nosys go: $gk"; bad=1; }
# E052: 宣言の片方を落とす変異 — ksyscall を落とせば ksyscall_loader で止まり、usdt を落としても ksyscall は OK、宣言なしは止まる
[ "$(chk abi.decl_no_ksyscall "$TM")" = 'checked kind=3 unmet=ksyscall_loader' ] && echo "mutant abi.decl_no_ksyscall ok" || { echo "BAD no_ksyscall"; bad=1; }
[ "$(chk abi.decl_no_usdt "$TM")" = 'checked kind=0 unmet=' ] && echo "mutant abi.decl_no_usdt ok (ksyscall)" || { echo "BAD no_usdt"; bad=1; }
[ "$(chk abi.decl_cilium022 "$TM")" = 'checked kind=3 unmet=ksyscall_loader' ] && echo "mutant abi.decl_cilium022 ok (ksyscall)" || { echo "BAD cilium022"; bad=1; }
chown -R "$U:$(id -g "$U")" "$D"
exit $bad
