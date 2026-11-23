//go:build spinelbpf_mutation

package main

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

// TestHookNfLenL2 は E128 の H7 (a) (host、root): 双子の len を hook に依らず n に (nf-len-l2) — 差動の最初の差が n_in の行 (PRE_ROUTING の frame) の
// Out の len。
func TestHookNfLenL2(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "nf-len-l2")
	h := buildHarnesses(t, nfData("t_nf.rb"))
	os.Unsetenv("SPINELBPF_MUTATION")
	script := tNfScript()
	d := ringDiff(feed(t, false, script, h.twinBin), feed(t, true, script, h.kernelBin))
	t.Logf("len-l2: %s", d)
	if d == "" || !strings.HasPrefix(d, "row n_in ") || !strings.Contains(d, "\"Out[2]=") {
		t.Errorf("len-l2: want the first difference at row n_in on \"Out[2]=\", got %q", d)
	}
}

// TestHookNfSwapVerdict は E128 の H7 (b) (host、root、自分の netns だけ): frontend が accept と drop を入れ替えると、実の attach で送れるのが 37〜200 の
// 164 個・EPERM が 36 個になる (nfattach.want と違う — 変異が実の netfilter の振る舞いに届く)。
func TestHookNfSwapVerdict(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "nf-swap-verdict")
	exe := buildDataProgram(t, nfData("nfattach.rb"), lpmConfig(t))
	os.Unsetenv("SPINELBPF_MUTATION")
	netns, rest := nfAttach(t, exe)
	t.Logf("swapped:\n%s%s", netns, rest)
	var lens []string
	for n := 37; n <= 200; n++ {
		lens = append(lens, strconv.Itoa(n))
	}
	want := "sent ok=164 eperm=36 other=0 got=164\nlens=" + strings.Join(lens, ",") + "\nOut0=3 Out1=2 Out2=228 runs_ge_200=true\n"
	if rest != want {
		t.Errorf("swapped verdicts: got\n%s\nwant\n%s", rest, want)
	}
}
