//go:build spinelbpf_mutation

package main

import (
	"strings"
	"testing"
)

// TestHookUstrNullStatus は E081 の H4 (b) (root): hook ustr-null-status (双子の NULL の status を 0 に) で、差動の NULL の行の status だけが落ちる。
func TestHookUstrNullStatus(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	t.Setenv("SPINELBPF_MUTATION", "ustr-null-status")
	h := buildHarnesses(t, uprobeSrc("up_str"))
	rows := uprobeStrRows()
	script := uprobeScript("on_greet", rows, "Events")
	kn := feed(t, true, "child\n"+script, h.kernelBin, cfixPath())
	tw := feed(t, false, childTask(t, kn)+script, h.twinBin)
	kn = strings.Replace(kn, kn[:strings.Index(kn, "\n")+1], "ok\n", 1)
	bad := uprobeCompare(tw, kn)
	t.Logf("%d mismatching lines: %v", len(bad), bad)
	if len(bad) == 0 {
		t.Fatalf("the NULL status hook changed nothing — the control is not sensitive")
	}
	for _, b := range bad {
		if !strings.Contains(b, "Events#0.status=0 | kernel Events#0.status=-14") && !strings.Contains(b, "Stats[") {
			t.Errorf("a mismatch outside the NULL row's status (and the count it selects): %s", b)
		}
	}
}
