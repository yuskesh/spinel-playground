//go:build spinelbpf_mutation

package main

import (
	"testing"
)

// E117 の H6: hook `fentry-arg-swap` (ctx.arg の slot 0 と 5 を入れ替える — 両方とも宣言の u64 なので schema の照合を通る) — kernel の
// Out[1]=21・Out[4]=48 (16 × 3) になり、双子 (16・63) と違う (意図した理由 — 引数の slot の取り違え)。
func TestHookFentryArgSwap(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "fentry-arg-swap")
	h := buildHarnesses(t, fentryIntSrc())
	k, w := fentryIntDiff(t, h, true)
	t.Log(k)
	wantLines(t, k, "Out[0]=3", "Out[1]=21", "Out[2]=18", "Out[3]=19", "Out[4]=48")
	wantLines(t, w, fentryIntWant...)
}
