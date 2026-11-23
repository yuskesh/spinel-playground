//go:build spinelbpf_mutation

package main

import (
	"strings"
	"testing"
)

// E124 の H5: hook `redirect-fallback-drop` (redirect_map の fallback を "drop" に) — kernel の key 1 / 3 の戻り値が 1 (XDP_DROP) になり、
// 双子 (2) と違う (意図した理由 — fallback の取り違え)。
func TestHookRedirectFallbackDrop(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "redirect-fallback-drop")
	h := buildHarnesses(t, redirSrc())
	k := redirRets(feed(t, true, redirScript(), h.kernelBin))
	w := redirRets(feed(t, false, redirScript(), h.twinBin))
	if strings.Join(k, " ") != "ret=4 ret=1 ret=4 ret=1" {
		t.Errorf("mutated kernel: want ret=4 ret=1 ret=4 ret=1, got %v", k)
	}
	if strings.Join(w, " ") != "ret=4 ret=2 ret=4 ret=2" {
		t.Errorf("twin: want ret=4 ret=2 ret=4 ret=2, got %v", w)
	}
}
