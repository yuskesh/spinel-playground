//go:build spinelbpf_mutation

package main

import (
	"fmt"
	"testing"
)

// E142 の H6: hook `tpstr-no-status` (tracepoint の user_str の read_str の status の store を落とす) — kernel の 4 つの event の status は 0
// (record.make の 0 のまま)、双子は 18 / 32 / 1 / −14 — 差動が落ちる (意図した理由 — status の欠け)。
func TestHookTpStrNoStatus(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "tpstr-no-status")
	h := buildHarnesses(t, tpStrSrc())
	k, w := tpStrDiff(t, h)
	t.Logf("kernel %v", ringLines(k))
	t.Logf("twin   %v", ringLines(w))
	for i := range e142Paths {
		wantLines(t, k, fmt.Sprintf("Events#%d.status=0", i))
	}
	wantLines(t, w, "Events#0.status=18", "Events#3.status=-14")
}
