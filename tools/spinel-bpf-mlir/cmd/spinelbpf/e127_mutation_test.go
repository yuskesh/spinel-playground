//go:build spinelbpf_mutation

package main

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

// TestHookCgWinL2 は E127 の H7 (a) (host、root): 双子の window と len を eth を外さない bytes から (cg-win-l2) — 差動の最初の差が c_bounds の len 0 の行の
// Out の dump。
func TestHookCgWinL2(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "cg-win-l2")
	h := buildHarnesses(t, cgData("t_cg.rb"))
	os.Unsetenv("SPINELBPF_MUTATION")
	script := tCgScript()
	d := ringDiff(feed(t, false, script, h.twinBin), feed(t, true, script, h.kernelBin))
	t.Logf("win-l2: %s", d)
	if d == "" || !strings.HasPrefix(d, "row c_bounds ") || !strings.Contains(d, "\"Out[0]=") {
		t.Errorf("win-l2: want the first difference at row c_bounds on \"Out[0]=\", got %q", d)
	}
}

// TestHookCgSwapVerdict は E127 の H7 (b) (host、root、子の cgroup だけ): frontend が allow と deny を入れ替えると、実の attach で ingress は 37〜200 の 164 個を受け、
// egress は 1〜36 が EPERM になる (cgattach.want と違う — 変異が実の cgroup の振る舞いに届く)。
func TestHookCgSwapVerdict(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "cg-swap-verdict")
	exe := buildDataProgram(t, cgData("cgattach.rb"), lpmConfig(t))
	os.Unsetenv("SPINELBPF_MUTATION")
	out, cg := cgAttach(t, exe)
	t.Logf("swapped:\n%s%s", out, cg)
	var lens []string
	for n := 37; n <= 200; n++ {
		lens = append(lens, strconv.Itoa(n))
	}
	l := strings.Join(lens, ",")
	want := "in sent=200 got=164\nin lens=" + l + "\nout ok=164 eperm=36 other=0 got=164\nout lens=" + l + "\nOut0=228 Out1=17\nleave=0 exists=0\n"
	if out != want {
		t.Errorf("swapped verdicts: got\n%s\nwant\n%s", out, want)
	}
}
