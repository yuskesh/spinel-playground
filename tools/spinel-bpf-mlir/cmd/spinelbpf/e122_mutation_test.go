//go:build spinelbpf_mutation

package main

import (
	"os"
	"strings"
	"testing"
)

// TestHookAdjhMutations は E122 の H5 (host、root): 変異の対照の検出器の列 — 各々で双子と kernel の出力が食い違い、最初の食い違いが a_bounds の行の
// status (Out[0])。adjh-bound は harness の双子 (縮める側の境界を 13 byte に)、adjh-neg は frontend (delta の符号を反す — kernel の側の ELF だけ)。
func TestHookAdjhMutations(t *testing.T) {
	requireUnverified(t)
	script := tAdjhScript()
	for _, m := range []struct{ name, hook string }{
		{"bound (双子の縮める側の境界を 13 に)", "adjh-bound"},
		{"neg (delta の符号を反す)", "adjh-neg"},
	} {
		t.Setenv("SPINELBPF_MUTATION", m.hook)
		h := buildHarnesses(t, adjhData("t_adjh.rb"))
		os.Unsetenv("SPINELBPF_MUTATION")
		d := ringDiff(feed(t, false, script, h.twinBin), feed(t, true, script, h.kernelBin))
		t.Logf("%s: %s", m.name, d)
		if d == "" || !strings.HasPrefix(d, "row a_bounds ") || !strings.Contains(d, "\"Out[0]=") {
			t.Errorf("%s: want the first difference at row a_bounds on \"Out[0]=\", got %q", m.name, d)
		}
	}
}
