//go:build spinelbpf_mutation

package main

import (
	"strings"
	"testing"
)

// E129 の H5: hook `skassign-absent-zero` (ref_check の absent の腕の番兵 −2 を 0 に) — kernel の 2 つ目の run (k 1 — entry 無し) の Out[0] が 0 に
// なり、双子 (−2) と違う (意図した理由 — entry 無しを「選んだ」と区別できない形)。
func TestHookSkAssignAbsentZero(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "skassign-absent-zero")
	h := buildHarnesses(t, skSrc())
	k := skLines(feed(t, true, skScript(), h.kernelBin), "Out[", "ret=")
	w := skLines(feed(t, false, skScript(), h.twinBin), "Out[", "ret=")
	t.Log("kernel ", k)
	t.Log("twin ", w)
	if strings.Join(k, " ") != "ret=1 Out[0]=0 Out[1]=1 ret=1 Out[0]=0 Out[1]=2 ret=1 Out[0]=-91 Out[1]=3" {
		t.Errorf("mutated kernel: want Out[0]=0 on the absent run, got %v", k)
	}
	if strings.Join(w, " ") != "ret=1 Out[0]=0 Out[1]=1 ret=1 Out[0]=-2 Out[1]=2 ret=1 Out[0]=-91 Out[1]=3" {
		t.Errorf("twin: want Out[0]=-2 on the absent run, got %v", w)
	}
}
