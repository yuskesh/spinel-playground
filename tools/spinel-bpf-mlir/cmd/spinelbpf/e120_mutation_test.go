//go:build spinelbpf_mutation

package main

import (
	"os"
	"strings"
	"testing"
)

// TestHookCtxfIfxZero は E120 の H6 (a) (host、root): 双子の ingress_ifindex を 0 に (ifx-zero) — 差動の最初の差が f_bounds の ifx の行の Out[0]。
func TestHookCtxfIfxZero(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "ifx-zero")
	h := buildHarnesses(t, ctxfData("t_ctxf.rb"))
	os.Unsetenv("SPINELBPF_MUTATION")
	script := tCtxfScript()
	d := ringDiff(feed(t, false, script, h.twinBin), feed(t, true, script, h.kernelBin))
	t.Logf("ifx-zero: %s", d)
	if d == "" || !strings.HasPrefix(d, "row f_bounds ") || !strings.Contains(d, "\"Out[0]=") {
		t.Errorf("ifx-zero: want the first difference at row f_bounds on \"Out[0]=\", got %q", d)
	}
}

// TestHookCtxfNoMarkStore は E120 の H6 (b) (host、root、自分の netns の lo だけ): frontend が mark の store を落とすと、差動の最初の差が mark_in の行の
// Out[3] (双子 7・kernel 0)、実の attach で Out2 と Out3 が 0。
func TestHookCtxfNoMarkStore(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "no-mark-store")
	h := buildHarnesses(t, ctxfData("t_ctxf.rb"))
	exe := buildDataProgram(t, ctxfData("ctxfattach.rb"), lpmConfig(t))
	os.Unsetenv("SPINELBPF_MUTATION")
	script := tCtxfScript()
	d := ringDiff(feed(t, false, script, h.twinBin), feed(t, true, script, h.kernelBin))
	t.Logf("no-mark-store: %s", d)
	if d == "" || !strings.HasPrefix(d, "row f_bounds ") || !strings.Contains(d, "\"Out[3]=") {
		t.Errorf("no-mark-store: want the first difference at row f_bounds on \"Out[3]=\", got %q", d)
	}
	netns, rest := ctxfAttach(t, exe)
	t.Logf("no-mark-store attach:\n%s%s", netns, rest)
	if want := "sent ok=10 got=10\nOut0=1 Out1=52 Out2=0 Out3=0\n"; rest != want {
		t.Errorf("no-mark-store attach: got\n%s\nwant\n%s", rest, want)
	}
}
