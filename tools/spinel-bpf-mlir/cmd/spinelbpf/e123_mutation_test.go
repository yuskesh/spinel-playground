//go:build spinelbpf_mutation

package main

import (
	"os"
	"strings"
	"testing"
)

// TestHookAdjtMutations は E123 の H5 (host、root): 変異の対照の検出器の列 — 各々で双子と kernel の出力が食い違い、最初の食い違いが t_bounds の行の
// status か窓の行。adjt-bound は harness の双子 (縮める側の境界を 13 byte に)、adjt-zero は frontend (delta を 0 に — kernel の側の ELF だけ)。
func TestHookAdjtMutations(t *testing.T) {
	requireUnverified(t)
	script := tAdjtScript()
	for _, m := range []struct{ name, hook string }{
		{"bound (双子の縮める側の境界を 13 に)", "adjt-bound"},
		{"zero (delta を 0 に)", "adjt-zero"},
	} {
		t.Setenv("SPINELBPF_MUTATION", m.hook)
		h := buildHarnesses(t, adjtData("t_adjt.rb"))
		os.Unsetenv("SPINELBPF_MUTATION")
		d := ringDiff(feed(t, false, script, h.twinBin), feed(t, true, script, h.kernelBin))
		t.Logf("%s: %s", m.name, d)
		if d == "" || !strings.HasPrefix(d, "row t_bounds ") || !strings.Contains(d, "\"Out[") {
			t.Errorf("%s: want the first difference at row t_bounds on an Out line, got %q", m.name, d)
		}
	}
}
