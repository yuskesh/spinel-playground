#!/bin/bash
# scripts/gate-vm-unit.sh — --vm-root の転送の wire の対照 (E068 H1〜H3a — 非 root・VM なし・BPF なし)。
# 正は本物の guest の loop (gate-vm-guest.sh) を裏で走らせ、負は応答を壊す偽の guest で、名前の付いた観測を照らす。
#   gate-vm-unit.sh <出力の dir — まだ無い dir>
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="${1:?出力の dir}"; [ ! -e "$W" ] || { echo "gate-vm-unit: 出力が既に在る: $W" >&2; exit 2; }
mkdir -p "$W/bin" || exit 2
cat > "$W/bin/sudo" <<EOF
#!/bin/bash
: > "$W/sudo-called"; exit 99
EOF
cat > "$W/dump" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" > "$DUMP_OUT"
EOF
cat > "$W/showenv" <<'EOF'
#!/bin/bash
env | LC_ALL=C sort
EOF
chmod +x "$W/bin/sudo" "$W/dump" "$W/showenv"
export PATH="$W/bin:$PATH"
fails=0 n=0
ok() { echo "$1: ok"; }; no() { echo "$1: FAIL ($2)"; fails=$((fails + 1)); }
new_q() { # $1 名前 → OUT を作る
  OUT="$W/$1"; mkdir -p "$OUT/queue/req" "$OUT/queue/resp"; RID=$(printf '%016x' $((0x1000 + n))); n=$((n + 1)); printf '%s' "$RID" > "$OUT/queue/run-id"
}
# 走らせる: 本体の script を gate の環境で (main の pid が vm_fatal の宛先)。JOB は枠の秒
harness() { # $1 OUT、$2 本体の script の file、$3 枠の秒、$4 ONLY
  env GATE_VM_OUT="$1" GATE_VM_RUN_ID="$RID" GATE_VM_LABEL=t GATE_VM_JOB_LIMIT="$3" GATE_VM_ONLY="${4:-}" W="$W" OUT="$1" \
    bash -c 'set -euo pipefail; . "$0/scripts/gate-mode.sh"; die() { echo "gate: FAIL: $*" >&2; exit 1; }; gate_mode_init --vm-root; . "$1"' "$HERE" "$2"
}
guest_on() { # 本物の guest の loop を裏で (保存の故障の誤りの文は捨てる)
  ( . "$HERE/scripts/gate-vm-guest.sh"; vm_guest_loop "$1/queue" "$RID" "${2:-30}" 2> /dev/null || : > "$1/queue/guest-exited" ) &
  GPID=$!
}
guest_off() { : > "$1/queue/stop"; wait "$GPID" 2>/dev/null; }

### 正 (本物の loop)
new_q pos; guest_on "$OUT"
cat > "$W/pos.sh" <<'EOF'
cd "$OUT"
# argv の byte (空文字・空白・*・quote・改行)
DUMP_OUT_FILE="$OUT/args.bin"
rsudo env "DUMP_OUT=$DUMP_OUT_FILE" "$W/dump" '' 'a b' '*' $'x\ny\n' "q'\"uo"
printf '%s\0' '' 'a b' '*' $'x\ny\n' "q'\"uo" | cmp - "$DUMP_OUT_FILE"
# sudo と同じ VAR=val の前置、env は明示だけ (呼び手の環境は漏れない)
TEST_LEAK=1 rsudo FOO=bar "$W/showenv" > "$OUT/env.out"
grep -qx 'FOO=bar' "$OUT/env.out"; ! grep -q TEST_LEAK "$OUT/env.out"; grep -qx 'HOME=/root' "$OUT/env.out"; grep -qx "SUDO_UID=$(id -u)" "$OUT/env.out"
# rc は対象の command のものがそのまま
for want in 0 1 124 134; do got=0; rsudo sh -c "exit $want" || got=$?; [ "$got" = "$want" ]; done
# stdout と stderr は分かれ、末尾の改行の無いものと NUL・pipe も byte で
rsudo sh -c 'printf "a\nb"; printf "E" >&2' > "$OUT/o" 2> "$OUT/e"
[ "$(od -An -c "$OUT/o" | tr -d ' \n')" = 'a\nb' ]; [ "$(cat "$OUT/e")" = E ]
rsudo sh -c 'printf "x\0y\n"' | od -An -c | tr -d ' \n' > "$OUT/p"; [ "$(cat "$OUT/p")" = 'x\0y\n' ]
s=$(rsudo sh -c 'seq 1 20000' | wc -l); [ "$s" = 20000 ]
# cwd
[ "$(rsudo pwd)" = "$OUT" ]
# 順序: job は連番
[ "$(cat "$OUT/queue/counter")" = 10 ]
: > "$OUT/reached"
EOF
harness "$OUT" "$W/pos.sh" 30 > "$OUT/log" 2>&1; rc=$?; guest_off "$OUT"
[ "$rc" = 0 ] && [ -e "$OUT/reached" ] && [ ! -e "$OUT/queue/FATAL" ] && ok positive || { no positive "rc $rc"; tail -5 "$OUT/log"; }
[ ! -e "$W/sudo-called" ] && ok no-sudo-on-vm-path || no no-sudo-on-vm-path "sudo が呼ばれた"

### 偽の guest の故障 — 本体は 1 つの rsudo、FATAL の文と rc 75 と後続が走らないことを照らす
fake() { # $1 故障の名前: 応答を作って置く
  local q="$OUT/queue" id=000001 r t i mode=$1
  for i in $(seq 1 400); do [ -d "$q/req/$id" ] && break; sleep 0.01; done; r="$q/req/$id"
  [ "$mode" = none ] && return
  [ "$mode" = late ] && sleep 2
  [ "$mode" = guest_gone ] && { : > "$q/guest-exited"; return; }
  t="$q/resp/.$id.tmp"; mkdir "$t"; printf 'out' > "$t/stdout"; : > "$t/stderr"; printf '0' > "$t/rc"
  local run=$RID job=$id transport=ok argv cwd env so se rrc=0
  argv=$(awk -F'\t' '$1=="argv"{print $2}' "$r/meta"); cwd=$(awk -F'\t' '$1=="cwd"{print $2}' "$r/meta"); env=$(awk -F'\t' '$1=="env"{print $2}' "$r/meta")
  so=$(sha256sum "$t/stdout" | cut -c1-64); se=$(sha256sum "$t/stderr" | cut -c1-64)
  case "$mode" in
    other_run) run=ffffffffffffffff ;; other_job) job=000099 ;; other_argv) argv=0000 ;;
    partial) printf 'cut' > "$t/stdout" ;; # hash は元の 3 byte の 'out' のまま
    guest_limit) transport=guest_limit ;; bad_rc) printf 'x' > "$t/rc" ;;
  esac
  printf 'run\t%s\njob\t%s\nargv\t%s\ncwd\t%s\nenv\t%s\ntransport\t%s\nrc\t%s\nstdout\t%s\nstderr\t%s\n' "$run" "$job" "$argv" "$cwd" "$env" "$transport" "$rrc" "$so" "$se" > "$t/meta"
  case "$mode" in no_rc) rm "$t/rc" ;; no_stdout) rm "$t/stdout" ;; no_stderr) rm "$t/stderr" ;; no_meta) rm "$t/meta" ;; esac
  mv "$t" "$q/resp/$id"
}
fault() { # 名前 故障 枠 FATAL の文
  new_q "f-$1"
  printf 'rsudo true\n: > "$OUT/reached"\n' > "$OUT.sh"
  fake "$2" & local f=$!
  harness "$OUT" "$OUT.sh" "$3" > "$OUT/log" 2>&1; local rc=$?; wait "$f" 2>/dev/null
  if [ "$rc" = 75 ] && [ ! -e "$OUT/reached" ] && grep -qF -- "$4" "$OUT/queue/FATAL" 2>/dev/null; then ok "$1"; else no "$1" "rc $rc、FATAL: $(cat "$OUT/queue/FATAL" 2>/dev/null)"; fi
}
fault other-run other_run 10 '応答の run が違う'
fault other-job other_job 10 '応答の job が違う'
fault other-argv other_argv 10 '応答の argv の hash が違う'
fault missing-rc no_rc 10 '応答に rc が無い'
fault missing-stdout no_stdout 10 '応答に stdout が無い'
fault missing-stderr no_stderr 10 '応答に stderr が無い'
fault missing-meta no_meta 10 '応答に meta が無い'
fault partial-save partial 10 '応答の stdout が途中までか壊れている'
fault bad-rc bad_rc 10 '応答の rc が不正'
fault guest-limit guest_limit 10 '転送の故障: guest_limit'
fault no-response none 1 '応答が枠の中に来ない'
fault late-after-deadline late 1 '応答が枠の中に来ない'
fault guest-gone guest_gone 10 'guest が終わった'

# the host was stopped during the window (the bpf-mlir reviewer's counterexample): SIGSTOP the host's shell after the request, put a correct response after the window and SIGCONT — a response found then is not accepted
new_q f-late-stopped
printf 'echo $$ > "$OUT/shell"\nrsudo true\n: > "$OUT/reached"\n' > "$OUT.sh"
( for _ in $(seq 1 400); do [ -d "$OUT/queue/req/000001" ] && [ -s "$OUT/shell" ] && break; sleep 0.01; done; sleep 0.3; p=$(cat "$OUT/shell"); kill -STOP "$p"; sleep 4.2; fake ok; kill -CONT "$p" ) & f=$!
harness "$OUT" "$OUT.sh" 3 > "$OUT/log" 2>&1; rc=$?; wait "$f" 2>/dev/null
[ "$rc" = 75 ] && [ ! -e "$OUT/reached" ] && grep -qF '応答が枠の後に届いた' "$OUT/queue/FATAL" 2>/dev/null && ok late-host-stopped || no late-host-stopped "rc $rc、FATAL: $(cat "$OUT/queue/FATAL" 2>/dev/null)"

# 保存できない guest: 本物の loop が止まる → host は guest の終わりで止まる
new_q f-save-unable; chmod a-w "$OUT/queue/resp"; guest_on "$OUT"
printf 'rsudo true\n: > "$OUT/reached"\n' > "$OUT.sh"
harness "$OUT" "$OUT.sh" 10 > "$OUT/log" 2>&1; rc=$?; wait "$GPID" 2>/dev/null; chmod u+w "$OUT/queue/resp"
[ "$rc" = 75 ] && [ ! -e "$OUT/reached" ] && grep -qF 'guest が終わった' "$OUT/queue/FATAL" && ok save-unable || no save-unable "rc $rc"

### a transport failure is not swallowed by the caller's context (the bpf-mlir reviewer): pipeline, $(...), || true, if, rc=$?, negation
wiring() { # 名前 本体の 1 行
  new_q "w-$1"
  printf '%s\n: > "$OUT/reached"\n' "$2" > "$OUT.sh"
  fake no_rc & local f=$!
  harness "$OUT" "$OUT.sh" 10 > "$OUT/log" 2>&1; local rc=$?; wait "$f" 2>/dev/null
  [ "$rc" = 75 ] && [ ! -e "$OUT/reached" ] && ok "wire-$1" || no "wire-$1" "rc $rc、後続 $([ -e "$OUT/reached" ] && echo 走った || echo 無し)"
}
wiring pipe-or-true 'rsudo x | cat || true'
wiring pipe-pipefail 'set +o pipefail; rsudo x | cat || true'
wiring cmdsub 'o=$(rsudo x) || true'
wiring cmdsub-pipe 'o=$(rsudo x 2>/dev/null | wc -l) || true'
wiring rc-capture 'rc=0; rsudo x || rc=$?'
wiring or-true 'rsudo x || true'
wiring if-cond 'if rsudo x; then :; else :; fi'
wiring negate '! rsudo x || true'
wiring subshell '( rsudo x ) || true'

### 故障の後の rsudo (queue の FATAL は残る)
new_q f-after-fatal; : > "$OUT/queue/FATAL"
printf 'rsudo true\n: > "$OUT/reached"\n' > "$OUT.sh"
harness "$OUT" "$OUT.sh" 2 > "$OUT/log" 2>&1; rc=$?
[ "$rc" = 75 ] && [ ! -e "$OUT/reached" ] && ok after-fatal || no after-fatal "rc $rc"

### mode の入口 (H1・H3・H3a)
entry() { # 名前 期待の文 — 環境は呼び手が付ける
  local name=$1 want=$2; shift 2; local out rc=0
  out=$(env "$@" bash -c 'set -euo pipefail; . "$0/scripts/gate-mode.sh"; gate_mode_init --vm-root' "$HERE" 2>&1) || rc=$?
  [ "$rc" = 64 ] && grep -qF -- "$want" <<< "$out" && ok "$name" || no "$name" "rc $rc: $out"
}
new_q entry; O="$OUT"; R="$RID"
entry no-out 'GATE_VM_OUT' GATE_VM_RUN_ID="$R" GATE_VM_LABEL=t
entry bad-run 'GATE_VM_RUN_ID' GATE_VM_OUT="$O" GATE_VM_RUN_ID=xyz GATE_VM_LABEL=t
entry no-label 'GATE_VM_LABEL' GATE_VM_OUT="$O" GATE_VM_RUN_ID="$R"
entry wrong-run 'run id が違う' GATE_VM_OUT="$O" GATE_VM_RUN_ID=abcdefabcdefabcd GATE_VM_LABEL=t
entry unknown-only 'GATE_VM_ONLY の段' GATE_VM_OUT="$O" GATE_VM_RUN_ID="$R" GATE_VM_LABEL=t GATE_VM_ONLY=e004-live
entry verified-record 'VERIFIED_RECORD' GATE_VM_OUT="$O" GATE_VM_RUN_ID="$R" GATE_VM_LABEL=t VERIFIED_RECORD=E1
mkdir "$O/tmp-old"; entry output-exists '出力の dir が既に在る' GATE_VM_OUT="$O" GATE_VM_RUN_ID="$R" GATE_VM_LABEL=old
mkdir -p "$W/idbin"; printf '#!/bin/bash\n[ "${1:-}" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' > "$W/idbin/id"; chmod +x "$W/idbin/id"
entry host-root 'euid 0 は拒否' PATH="$W/idbin:$PATH" GATE_VM_OUT="$O" GATE_VM_RUN_ID="$R" GATE_VM_LABEL=t2

### 選択と台帳
new_q led
sel=$(env GATE_VM_OUT="$OUT" GATE_VM_RUN_ID="$RID" GATE_VM_LABEL=t bash -c 'set -euo pipefail; . "$0/scripts/gate-mode.sh"; gate_mode_init --vm-root; for s in e004-live "${GATE_VM_STAGES[@]}"; do if gate_root "$s"; then echo "$s"; fi; done; [ "$GATE_FULL" = 1 ]; gate_mode_finish 0 > /dev/null' "$HERE" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(wc -l <<< "$sel")" = 20 ] && ! grep -qx e004-live <<< "$sel" && [ "$(cut -f1 "$OUT/tmp-t/ledger.tsv" | wc -l)" = 20 ] && ok select-20 || no select-20 "rc $rc: $sel"
new_q led2
sel=$(env GATE_VM_OUT="$OUT" GATE_VM_RUN_ID="$RID" GATE_VM_LABEL=t GATE_VM_ONLY=e025-print,e006-abi bash -c 'set -euo pipefail; . "$0/scripts/gate-mode.sh"; gate_mode_init --vm-root; for s in "${GATE_VM_STAGES[@]}"; do if gate_root "$s"; then echo "$s"; fi; done; gate_mode_finish 0 > /dev/null' "$HERE" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s\n' $sel | LC_ALL=C sort | tr '\n' ' ')" = 'e006-abi e025-print ' ] && ok select-only || no select-only "rc $rc: $sel"
ledger_neg() { # 名前 本体 期待の文
  new_q "l-$1"
  rc=0; env GATE_VM_OUT="$OUT" GATE_VM_RUN_ID="$RID" GATE_VM_LABEL=t GATE_VM_ONLY=e025-print,e006-abi bash -c 'set -euo pipefail; . "$0/scripts/gate-mode.sh"; gate_mode_init --vm-root; eval "$1"; gate_mode_finish 0' "$HERE" "$2" > "$OUT/log" 2>&1 || rc=$?
  [ "$rc" = 75 ] && grep -qF -- "$3" "$OUT/queue/FATAL" && ok "ledger-$1" || no "ledger-$1" "rc $rc"
}
ledger_neg missing 'gate_root e006-abi' '台帳の段の集合が選択と違う'
ledger_neg duplicate 'gate_root e006-abi; gate_root e025-print; gate_root e006-abi' '段が 2 回'

### 追補 3: e005 の want の e068 の行は理由の文まで固定する (gate.sh の実の 1 行を取り出して走らせる)
l=$(grep -F e068_guard_stops.tsv "$HERE/scripts/gate.sh"); c=${l#*e062_guard_stops.tsv\"; }; c=${c%; \} | LC_ALL=C sort)}
E684="$HERE/third_party/bpf-mlir/docs/experiments/results/E684/fixtures/copy_pid_ebpf.bpf.o"
REASON=$(cut -f3 "$HERE/test/load/fixture/e068_guard_stops.tsv")
reason_case() { # 名前 期待 (same か mismatch) gate-load.txt の中身
  local T="$W/reason-$1"; mkdir "$T"; printf '%s' "$3" > "$T/gate-load.txt"
  local o; o=$(HERE="$HERE" TMPDIR="$T" bash -c "$c")
  case "$2" in
    same) [ "$o" = "shape $E684" ] && ok "reason-$1" || no "reason-$1" "$o" ;;
    mismatch) [ "$(wc -l <<< "$o")" = 2 ] && grep -qxF "reason-mismatch $E684" <<< "$o" && ok "reason-$1" || no "reason-$1" "$o" ;;
  esac
}
reason_case match same "$E684	ok	shape	$REASON"$'\n'
reason_case other-reason mismatch "$E684	ok	shape	symbol other is undefined"$'\n'
reason_case other-stage mismatch "$E684	ok	ok	$REASON"$'\n'
reason_case absent mismatch "other	ok	shape	$REASON"$'\n'

### 対照: 既定の経路は sudo に届く (no-sudo の観測が効く)
rm -f "$W/sudo-called"; : > "$W/lock"
GATE_ROOT_LOCK="$W/lock" bash -c '. "$0/scripts/gate-mode.sh"; die() { exit 1; }; gate_mode_init; rsudo true; exit 0' "$HERE" > /dev/null 2>&1
[ -e "$W/sudo-called" ] && ok sudo-shim-control || no sudo-shim-control "shim に届かない"
echo "gate-vm-unit: FAIL $fails"
[ "$fails" = 0 ]
