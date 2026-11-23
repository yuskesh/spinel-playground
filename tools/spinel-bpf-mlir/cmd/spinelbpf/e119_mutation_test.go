//go:build spinelbpf_mutation

package main

import (
	"strings"
	"testing"
)

// E119 の H5: hook `kcopy-ring-drop` (予約への kfield.copy を落とす — comm は store_record の 0 のまま) — kernel の event の comm が全て 0 になり、
// 双子 ("e119ring") と違う (意図した理由 — 写しの段が効く)。
func TestHookKcopyRingDrop(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "kcopy-ring-drop")
	h := buildHarnesses(t, kcopyRingSrc())
	k, w, kids := kcopyRingDiff(t, h)
	t.Log(k)
	zero := strings.Repeat("00", 16)
	wantLines(t, k, "Events#0.comm="+zero, "Events#1.comm="+zero, "Events#0.pid="+kids[0], "Events drained=2")
	wantLines(t, w, kcopyRingWant(kids)...)
}
