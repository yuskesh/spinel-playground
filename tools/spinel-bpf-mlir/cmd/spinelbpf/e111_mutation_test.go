//go:build spinelbpf_mutation

package main

import (
	"strings"
	"testing"
)

// E111 の H7: hook `kretval-zext` (kretprobe の i32 の戻り値を i64 に広げる所を零の拡張に — 試験の build だけ) — kernel の Rets[2] が
// 2 × (2^32 − 14) = 8589934564 になり、双子 (Ruby の意味 −28) と違う (意図した理由 — 符号の拡張の取り違え)。
func TestHookKretvalZext(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "kretval-zext")
	h := buildHarnesses(t, kretSrc())
	k, w, _ := kretDiff(t, h, true, []int{3, 4, 0}, []int{-14, -14, 0})
	t.Log(k)
	if !strings.Contains(k, "Rets[2]=8589934564\n") || !strings.Contains(k, "Rets[0]=0\n") {
		t.Errorf("the mutated kernel should sum the zero-extended −14 twice (8589934564):\n%s", k)
	}
	if !strings.Contains(w, "Rets[2]=-28\n") {
		t.Errorf("the twin keeps Ruby's −28:\n%s", w)
	}
}
