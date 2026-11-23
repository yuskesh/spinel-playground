//go:build spinelbpf_mutation

package main

import (
	"strings"
	"testing"
)

// TestHookUprobePtrTrunc は E157 の H4 (root): hook uprobe-ptr-trunc (kernel の :ptr を下位 32 bit の符号拡張に — 照合は通る) で、差動の Edges の
// from / to と Held の値の行だけが落ちる (子の static の mutex の address は 2^32 を超える — 値で確かめる)。
func TestHookUprobePtrTrunc(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "uprobe-ptr-trunc")
	h := sysHarnesses(t, "up_libc_lock")
	kn, tw, addrs := lockDiff(t, h)
	bad := uprobeCompare(tw, kn)
	t.Logf("addresses %v, %d mismatching lines: %v", addrs, len(bad), bad)
	for _, a := range addrs {
		if len(a) < 11 { // 10 進で 11 桁以上 = 2^32 (4294967296 — 10 桁) を超える
			t.Fatalf("the child's address %s does not exceed 2^32 — the control cannot see a 32-bit cut", a)
		}
	}
	if len(bad) == 0 {
		t.Fatalf("the truncation hook changed nothing — the control is not sensitive")
	}
	for _, b := range bad {
		if !strings.Contains(b, "Edges#0.from=") && !strings.Contains(b, "Edges#0.to=") && !strings.Contains(b, "Held{") {
			t.Errorf("a mismatch outside the pointer values (edges and Held): %s", b)
		}
	}
}
