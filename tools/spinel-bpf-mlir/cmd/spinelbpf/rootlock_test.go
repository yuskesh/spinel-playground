package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// rootLock is bpf-mlir's host-wide root lock (E106 — at the bpf-mlir coordinator's request, 2026-10-04: bpf-mlir's root stages compare the whole host's links and routes before and after;
// the same file as bml's rsudo). SPINELBPF_ROOT_LOCK replaces it (for tests).
func rootLock() string {
	if p := os.Getenv("SPINELBPF_ROOT_LOCK"); p != "" {
		return p
	}
	return "/run/lock/bpf-mlir-root.lock"
}

// E165 (利用者の決定 2026-11-10 — root の試験は全て VM の 7.1.8 で、host の kernel に対して sudo を実行しない): root の呼び出しは VM の guest の中だけ。
// 印は boot ごとの乱数で、host の script (scripts/gate-vm.sh) が kernel の cmdline の spinelbpf_vm_mark=<印> と guest の env の SPINELBPF_VM_MARK に同じ値を置く。
// host の cmdline には在らないので env だけを偽っても通らない。sudo と cmdline は絶対 path で呼び手が渡す (対照は偽物だけを渡す — PATH に頼らず実 sudo に届く経路を作らない)。
const (
	realSudoPath = "/usr/bin/sudo"
	procCmdline  = "/proc/cmdline"
	vmMarkEnv    = "SPINELBPF_VM_MARK"
	vmMarkArg    = "spinelbpf_vm_mark="
	// rootSkipMsg は host で root の試験を止める文 — gate の TestHook の数え (scripts/gate.sh) がこの文を見る。
	rootSkipMsg = "root test: runs in the VM guest only (scripts/gate-vm.sh) — no guest mark"
)

// rootAllowed は cmdlinePath の file が今の印の token を持つときだけ真 (印が空なら偽)。
func rootAllowed(cmdlinePath, mark string) bool {
	if mark == "" || strings.ContainsAny(mark, " \t\n") {
		return false
	}
	b, err := os.ReadFile(cmdlinePath)
	if err != nil {
		return false
	}
	for _, f := range strings.Fields(string(b)) {
		if f == vmMarkArg+mark {
			return true
		}
	}
	return false
}

var rootNeededMu sync.Mutex

// recordRootNeeded は top-level の試験の名前を $TMPDIR/root_needed.txt に足す (gate が testdata/root_tests.txt と照らす — 走らなかった root の試験を黙らせない)。
func recordRootNeeded(t testing.TB) {
	rootNeededMu.Lock()
	defer rootNeededMu.Unlock()
	name := strings.SplitN(t.Name(), "/", 2)[0]
	dir := os.TempDir()
	f, err := os.OpenFile(filepath.Join(dir, "root_needed.txt"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatalf("recording the root test: %v", err)
	}
	defer f.Close()
	fmt.Fprintln(f, name)
}

// sudoCmd は `sudo -n args…` を lock の中で走らせる command — flock(1) が lock を持ったまま sudo を走らせ、終わりで放す (呼び出しの間だけ、
// -o で子に lock の fd を渡さない)。lock の file が無ければ止める (flock(1) は file を作るので先に確かめる — 黙って作らない — 作るのは bpf-mlir の側)。
// E108: 待ちは 600 秒 (gate の go test の timeout 30 分より十分短く — timeout で flock の子が残る形を無くす、SPINELBPF_ROOT_LOCK_WAIT で替える)、
// 待ちの切れは lock の path を名指す文を stderr に出して rc 125 (呼び手の試験の失敗の文に出る)。
// E165: guest の印が無ければ sudo を実行せず skip (root_needed に名を残す)。
func sudoCmd(t testing.TB, args ...string) *exec.Cmd {
	t.Helper()
	return sudoCmdAt(t, realSudoPath, procCmdline, args...)
}

// sudoCmdAt は sudoCmd の本体 (sudo と cmdline の path は呼び手が明示 — 試験は偽物だけを渡す)。
func sudoCmdAt(t testing.TB, sudoPath, cmdlinePath string, args ...string) *exec.Cmd {
	t.Helper()
	if !rootAllowed(cmdlinePath, os.Getenv(vmMarkEnv)) {
		recordRootNeeded(t)
		t.Skip(rootSkipMsg)
	}
	l := rootLock()
	if _, err := os.Stat(l); err != nil {
		t.Fatalf("the bpf-mlir root lock %s is missing (bpf-mlir's root stage creates it): %v", l, err)
	}
	w := "600"
	if v := os.Getenv("SPINELBPF_ROOT_LOCK_WAIT"); v != "" {
		w = v
	}
	sh := `flock -o -E 125 -w "$1" "$2" "$3" -n "${@:4}"; rc=$?; [ $rc != 125 ] || echo "the bpf-mlir root lock $2 was not free within $1 s (another holds it — sudoCmd, E108)" >&2; exit $rc`
	return exec.Command("bash", append([]string{"-c", sh, "rootlock", w, l, sudoPath}, args...)...) // rootlock:ok
}
