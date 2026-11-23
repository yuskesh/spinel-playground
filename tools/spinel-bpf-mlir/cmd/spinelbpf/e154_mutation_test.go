//go:build spinelbpf_mutation

package main

import "testing"

// E154 の追補 5: hook `kpath-leaf-swap` (経路の leaf の __sk_common.skc_daddr を同じ幅の __sk_common.skc_rcv_saddr に読み替える) — compile と load は
// 通り、kernel の event の daddr が自分の address 127.0.0.1 (16777343) になり、双子の 127.0.0.2 (33554559) と名指しで違う (意図した理由 — 経路の leaf が効く)。
func TestHookKpathLeafSwap(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "kpath-leaf-swap")
	h := buildHarnesses(t, kpathSrc("trace_kpath_sock"))
	k, w := kpathDiff(t, h)
	t.Log(k)
	wantLines(t, k, "Events#0.daddr=16777343", "Events#2.daddr=16777343", "Events drained=3")
	wantLines(t, w, "Events#0.daddr=33554559", "Events drained=3")
}
