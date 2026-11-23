//go:build spinelbpf_mutation

package main

import (
	"os/exec"
	"strings"
	"testing"
)

// E114 の H7: hook `tpfield-shift` (fd の宣言と読みの offset を両方 +8 — schema と op が一致した誤り、compile は通る) — kernel の harness の load が
// TargetRejected (reads tracepoint field syscalls/sys_enter_write.fd — 追補 1 の判定) で止まり (意図した理由 — field の位置の取り違えを load の前の照合が捕まえる)、双子は H3 の値のまま。
// load で止まるので実の事象に依らない。
func TestHookTpfieldShift(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "tpfield-shift")
	h := buildHarnesses(t, tpSrc())
	cmd := sudoCmd(t, h.kernelBin)
	cmd.Stdin = strings.NewReader("reset\ndump\n")
	b, err := cmd.CombinedOutput()
	out := string(b)
	t.Log(out)
	if _, ok := err.(*exec.ExitError); !ok || !strings.Contains(out, "TargetRejected") || !strings.Contains(out, "reads tracepoint field syscalls/sys_enter_write.fd") {
		t.Errorf("the mutated kernel harness must stop at load on the tracefs format (TargetRejected, tpfield fd), err=%v", err)
	}
	var in strings.Builder
	in.WriteString("reset\npoke Filter 0 4242\ntask 18219251273881\n")
	tpTwinRuns(&in)
	in.WriteString("dump\n")
	wantLines(t, feed(t, false, in.String(), h.twinBin), tpWant...)
}
