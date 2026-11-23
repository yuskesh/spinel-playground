//go:build spinelbpf_mutation

package main

import (
	"testing"
)

// E144 の H6: hook `fmod-select-swap` (on_guard の終端の arith.select の腕を入れ替える) — kernel の fexit が見る戻り値は Cfg 0 で −1・Cfg 1 で 4
// になり、双子 (4・−1) と違う (意図した理由 — guard の値と最後の値の取り違え)。
func TestHookFmodSelectSwap(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "fmod-select-swap")
	h := buildHarnesses(t, fmodRetSrc())
	k, w := fmodRetDiff(t, h)
	t.Logf("step 0 kernel: %v twin: %v", traceDumpLines(k[0]), traceDumpLines(w[0]))
	t.Logf("step 1 kernel: %v twin: %v", traceDumpLines(k[1]), traceDumpLines(w[1]))
	wantLines(t, k[0], "Out[3]=-1")
	wantLines(t, k[1], "Out[3]=4")
	wantLines(t, w[0], "Out[3]=4")
	wantLines(t, w[1], "Out[3]=-1")
}
