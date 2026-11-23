//go:build spinelbpf_mutation

package main

import (
	"strings"
	"testing"
)

// E113 の H7 (追補 3 と事後の訂正): hook `rawtp-index` (raw_tp の args の添字 0 と 1 を入れ替える — 試験の build だけ、引数の数の内なので sys_enter に
// attach は通る) — kernel の dump が双子 (H3 の値) と違う (意図した理由 — 添字の取り違え)。kernel の Seen[1]・Seen[2] の値は、harness が
// sys_enter に attach したまま test run をするので own の tgid の実の syscall が混ざりうる (root_mutation2.txt — 値は判定しない)。
func TestHookRawtpIndex(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "rawtp-index")
	h := buildHarnesses(t, rawtpSrc())
	k, w := rawtpTestRunDiff(t, h)
	t.Log(k)
	wantLines(t, k, "Seen[0]=0")
	wantLines(t, w, rawtpWant...)
	if strings.Join(traceDumpLines(k), "\n") == strings.Join(traceDumpLines(w), "\n") {
		t.Errorf("the swapped index must make the kernel differ from the twin:\n%s", k)
	}
}
