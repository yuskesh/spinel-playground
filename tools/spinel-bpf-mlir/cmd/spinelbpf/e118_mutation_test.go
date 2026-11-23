//go:build spinelbpf_mutation

package main

import (
	"strings"
	"testing"
)

// E118 の H6: hook `kstr-no-status` (kernel の文字列の status の store_field を落とす — st の member は store_record の 0 のまま) — kernel の event の
// st が 0・0 になり、双子 (14・32) と違う (意図した理由 — status を event に入れる形を差動が見る)。
func TestHookKstrNoStatus(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "kstr-no-status")
	h := buildHarnesses(t, kstrSrc())
	k, w := kstrDiff(t, h)
	t.Log(k)
	wantLines(t, k, "Events#0.st=0", "Events#1.st=0", "Events drained=2")
	wantLines(t, w, "Events#0.st=14", "Events#1.st=32")
	if strings.Join(kstrEvents(k), "\n") == strings.Join(kstrEvents(w), "\n") {
		t.Errorf("dropping the status store must make the kernel differ from the twin")
	}
}
