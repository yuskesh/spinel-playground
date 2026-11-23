//go:build spinelbpf_mutation

package main

import (
	"fmt"
	"strings"
	"testing"
)

// E145 の H5: hook `comm-skip` (task.comm を出さず status に 0 を置く) — kernel の 3 つの event の comm は 16 byte の 0 になり、双子 (prctl の
// 読み戻しと同じ comm) と違う (意図した理由 — comm を書く op の欠け)。
func TestHookCommSkip(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "comm-skip")
	h := buildHarnesses(t, commSrc("trace_comm"))
	k, w := commDiff(t, h)
	t.Logf("kernel %v", ringLines(k))
	t.Logf("twin   %v", ringLines(w))
	zero := strings.Repeat("0", 32)
	for i := range e145Names {
		wantLines(t, k, fmt.Sprintf("Events#%d.comm=%s", i, zero))
	}
	for i, c := range commLines(w) {
		wantLines(t, w, fmt.Sprintf("Events#%d.%s", i, c))
	}
}
