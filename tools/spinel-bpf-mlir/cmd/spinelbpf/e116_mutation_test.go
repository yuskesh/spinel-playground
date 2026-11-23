//go:build spinelbpf_mutation

package main

import (
	"testing"
)

// E116 の H6: hook `kread-offset` (read_scalar の offset を 8 減らす — how->mode の読みが how->flags (0) に) — mode の一致が起きず kernel の Out は
// 全て 0、双子は H3 の値 (意図した理由 — offset の取り違え)。
func TestHookKreadOffset(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "kread-offset")
	h := buildHarnesses(t, kreadSrc())
	k, w := kreadAttachDiff(t, h, true)
	t.Log(k)
	wantLines(t, k, "Out[0]=0", "Out[1]=0", "Out[2]=0", "Out[3]=0", "Out[4]=0")
	wantLines(t, w, kreadWant...)
}
