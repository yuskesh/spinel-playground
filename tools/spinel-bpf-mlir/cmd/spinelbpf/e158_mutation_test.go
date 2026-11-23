//go:build spinelbpf_mutation

package main

import (
	"strings"
	"testing"
)

// TestHookUserReadLenAbs は E158 の H4 (root): hook user-read-len-abs (kernel の output_buf の長さを絶対値に — 照合は通る) で、差動の
// `put -5 abc` の行 (count 0 → 5、data の先頭 3 byte) だけが落ちる。
func TestHookUserReadLenAbs(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "user-read-len-abs")
	kn, tw := bufDiff(t)
	bad := uprobeCompare(tw, kn)
	t.Logf("%d mismatching lines: %v", len(bad), bad)
	if len(bad) == 0 {
		t.Fatalf("the length hook changed nothing — the control is not sensitive")
	}
	for _, b := range bad {
		if !strings.Contains(b, "twin Writes#0.count=0 | kernel Writes#0.count=5") && !strings.Contains(b, "twin Writes#0.data=") {
			t.Errorf("a mismatch outside the negative-length row's count and data: %s", b)
		}
	}
}
