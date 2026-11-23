//go:build spinelbpf_mutation

package main

import (
	"strings"
	"testing"
)

// E153 の追補 1: hook `tp-copy-drop` (予約への ebpf.tp.field.copy を出さない — daddr / daddr_v6 は store_record の 0 のまま) — compile と load は
// 通り、kernel の event の daddr と daddr_v6 が全て 0 になり、双子 (127.0.0.1・v4-mapped・::1) と名指しの byte で違う (意図した理由 — 写しの段が効く)。
func TestHookTpCopyDrop(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "tp-copy-drop")
	h := buildHarnesses(t, tpArraySrc("ring"))
	k, w := tpArrayDiff(t, h, "on_state", "drain Events\n")
	t.Log(k)
	z4, z16 := strings.Repeat("00", 4), strings.Repeat("00", 16)
	wantLines(t, k, "Events#0.daddr="+z4, "Events#0.daddr_v6="+z16, "Events#3.daddr_v6="+z16, "Events drained=6")
	wantLines(t, w, "Events#0.daddr="+tpLoop4, "Events#0.daddr_v6="+tpMapped6, "Events#3.daddr_v6="+tpLoop6, "Events drained=6")
}
