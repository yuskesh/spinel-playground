//go:build spinelbpf_mutation

package main

import (
	"fmt"
	"testing"
)

// E146 の H6: hook `kprobe-ptr-swap` (:ptr の kprobe.arg の 2 と 3 を入れ替える — 両方 ptr の宣言なので照合を通る) — kernel の Out[0] は第 3 引数
// (do_sys_openat2 の how — kernel の stack の写しの address) になり fname と違い、双子 (fname) と違う (意図した理由 — 引数の register の取り違え)。
func TestHookKprobePtrSwap(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "kprobe-ptr-swap")
	h := buildHarnesses(t, ptrValSrc())
	k, w, fname := ptrValDiff(t, h)
	t.Logf("fname=%d kernel %v twin %v", fname, traceDumpLines(k), traceDumpLines(w))
	wantLines(t, w, fmt.Sprintf("Out[0]=%d", fname))
	for _, l := range traceDumpLines(k) {
		if l == fmt.Sprintf("Out[0]=%d", fname) {
			t.Errorf("with the arguments swapped the kernel still read fname (%d)", fname)
		}
	}
}
