#!/bin/bash
# scripts/gate.sh — commit の前の gate (CLAUDE.md)。出力を pipe に繋がない: `scripts/gate.sh && git commit …` か、file に落として rc を見る。
#   go vet と go test (-count=1 — cache で文書や生成物の変更を見落とさない)、submodule が汚れていないこと、例の生成物が commit 済みの形と一致すること (試験の中)。
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$HERE"
GO=${GO:-/usr/local/go/bin/go}
export GOFLAGS=-mod=mod TMPDIR="$HERE/build/tmp"
mkdir -p "$TMPDIR"
# gate を直列に (bpf-mlir E300 — 同じ tree で gate・試験・clone-check を同時に走らせると生成物を奪い合う)
exec 9>"$HERE/build/.gate.lock"
flock 9
for t in third_party/spinel/bin/spinel build/bpf-mlir/bin/ebpf-compile build/bpf-mlir/bin/ebpf-schema-check; do
  [ -x "$t" ] || { echo "gate: $t is missing — run scripts/setup.sh" >&2; exit 1; }
done
for s in third_party/bpf-mlir third_party/spinel; do
  if [ -n "$(git -C "$s" status --porcelain)" ]; then echo "gate: $s is dirty (do not edit submodules)" >&2; exit 1; fi
done
# E171: #!/bin/sh (dash) の script と、それが source する file が dash で読める (setup.sh が bash 専用の lib を source して README の手順が落ちた — E167 の誤り)
scripts/check-sh-dialect.sh "$HERE"
# E046: 入力の鍵が verified.tsv に無くて走った試験の一覧 (試験が書く — 最後に名指し)
rm -f "$TMPDIR/unverified.txt" "$TMPDIR/verified_off.txt" "$TMPDIR/root_needed.txt"
PKGS=$("$GO" list -e -f '{{.ImportPath}}' ./... | grep -v /third_party/) # E165: bml の test/caps 等は cgo の C を持つ Go の dir で ./... に入る — submodule は対象の外
"$GO" vet $PKGS
# -timeout 30m: 全てを走らせる off の gate は cmd/spinelbpf が 10 分 (go test の既定) を超えうる (E072 — 583 s → 600 s で timeout の panic)
"$GO" test -count=1 -timeout 30m -parallel "${GATE_JOBS:-8}" $PKGS # P018 E075: 独占でない試験を並行に — 既定 8 (nproc 20 の半分以下、4 は off の gate の cmd が 269 s で 250 s を超えた)、GATE_JOBS で絞れる
# 変異の対照の hook (試験の build tag だけ — P002 §3.4・E010)
"$GO" vet -tags spinelbpf_mutation $PKGS
# 選びが空の run を pass と数えない見張り (go-bpf-mlir E146 — `-run` の選びが 0 の試験で「no tests to run」の PASS になった): tag の file の TestHook の定義の数と、
# 走った (PASS) か鍵で skip した (SKIP の直前の行が requireUnverified の `verified <鍵> (E…)`) 最上位の TestHook の数が一致すること
HOOKS=$(grep -h "^func TestHook" $(grep -l "^//go:build spinelbpf_mutation" cmd/spinelbpf/*_test.go) | wc -l)
"$GO" test -count=1 -timeout 30m -v -tags spinelbpf_mutation -run TestHook ./cmd/spinelbpf > "$TMPDIR/hooks.txt" 2>&1 || { cat "$TMPDIR/hooks.txt"; exit 1; }
DONE=$(awk "/^--- PASS: TestHook/{n++} /^--- SKIP: TestHook/ && (p ~ /_test[.]go:[0-9]+: verified [0-9a-f]+ [(]E/ || p ~ /_test[.]go:[0-9]+: root test: runs in the VM guest only/){n++} {p=\$0} END{print n+0}" "$TMPDIR/hooks.txt")
if grep -q "no tests to run" "$TMPDIR/hooks.txt" || [ "$DONE" -ne "$HOOKS" ]; then
  echo "gate: the mutation hooks ran or were verified-skipped $DONE of $HOOKS TestHook tests — an empty or partial selection is not a pass" >&2
  exit 1
fi
echo "gate: mutation hooks $DONE / $HOOKS (passed or verified-skipped)"
# E161: 公開の形 (build tag spinelbpf_public — bpf-mlir v1.21.0 と go-bpf-mlir v0.19.0 の pin の対) の build と pin の単体の試験。import は開発の形のままで
# compile でき (書き換えは写しの道具の役)、公開の形の pin が腐るのを毎回捕まえる。cmd の公開の試験は選びが空でないことも見る
"$GO" vet -tags spinelbpf_public $PKGS
"$GO" build -tags spinelbpf_public -o /dev/null ./cmd/spinelbpf
"$GO" test -count=1 -tags spinelbpf_public ./internal/toolchain ./internal/version
"$GO" test -count=1 -v -tags spinelbpf_public -run '^TestPublic' ./cmd/spinelbpf > "$TMPDIR/public.txt" 2>&1 || { cat "$TMPDIR/public.txt"; exit 1; }
grep -q "^--- PASS: TestPublicSeamPin" "$TMPDIR/public.txt" || { echo "gate: TestPublicSeamPin did not run under -tags spinelbpf_public" >&2; exit 1; }
grep -q "^--- PASS: TestPublicVersionFlagWant" "$TMPDIR/public.txt" || { echo "gate: TestPublicVersionFlagWant did not run under -tags spinelbpf_public" >&2; exit 1; }
echo "gate: public form (spinelbpf_public) builds and its pin tests pass"
# E165: root の試験は host では実行しない (sudoCmd が skip して名を root_needed に残す)。off の run では集合が testdata/root_tests.txt と完全に一致、既定の run では部分集合 — 増減を黙らせない
ROOTL=cmd/spinelbpf/testdata/root_tests.txt
if [ -s "$TMPDIR/root_needed.txt" ]; then LC_ALL=C sort -u "$TMPDIR/root_needed.txt" > "$TMPDIR/root_needed.sorted"; else : > "$TMPDIR/root_needed.sorted"; fi
extra=$(LC_ALL=C comm -23 "$TMPDIR/root_needed.sorted" "$ROOTL")
if [ -n "$extra" ]; then echo "gate: root tests not in $ROOTL:" >&2; echo "$extra" >&2; exit 1; fi
if [ "${SPINELBPF_VERIFIED:-}" = off ]; then
  missing=$(LC_ALL=C comm -13 "$TMPDIR/root_needed.sorted" "$ROOTL")
  if [ -n "$missing" ]; then echo "gate: root tests listed in $ROOTL did not reach root on the host (SPINELBPF_VERIFIED=off):" >&2; echo "$missing" >&2; exit 1; fi
  echo "gate: root_needed matches $ROOTL ($(wc -l < "$ROOTL") tests — they run in the VM, scripts/gate-vm.sh)"
elif [ -s "$TMPDIR/root_needed.sorted" ]; then
  echo "gate: $(wc -l < "$TMPDIR/root_needed.sorted") root tests were skipped on the host because their key is not verified — run scripts/gate-vm.sh:"; sed "s/^/  /" "$TMPDIR/root_needed.sorted"
fi
if [ -s "$TMPDIR/unverified.txt" ]; then
  echo "gate: $(wc -l < "$TMPDIR/unverified.txt") tests ran because their input key is not in cmd/spinelbpf/testdata/verified.tsv (record with VERIFIED_RECORD=E<n>):"
  sed "s/^/  /" "$TMPDIR/unverified.txt"
else
  echo "gate: every verified-key test was skipped or recorded (0 unverified)"
fi
if [ -s "$TMPDIR/verified_off.txt" ]; then
  echo "gate: $(wc -l < "$TMPDIR/verified_off.txt") tests with a verified key ran because SPINELBPF_VERIFIED=off (and passed)"
fi
echo "gate: ok"
