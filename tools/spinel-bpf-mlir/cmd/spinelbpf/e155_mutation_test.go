//go:build spinelbpf_mutation

package main

import (
	"path/filepath"
	"testing"
)

// E155 の H3: hook `kaddr-zero` (ebpf.kptr.addr を定数 0 に — bpf-mlir E554 の H5 と同じ) — compile と load は通り、kernel の Last の addr が 0 になり
// 「addr ≠ 0・上位 16 bit 0xffff」が名指しで落ちる (意図した理由 — address の op が効く)。len と sector は正常と同じ (pointee の読みは変わらない)。
func TestHookKaddrZero(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "kaddr-zero")
	h := buildHarnesses(t, kaddrSrc())
	k, want := kaddrObserve(t, h, filepath.Join(repoRoot(), "build", "tmp"))
	t.Log(k)
	addr, _ := dumpInt(k, "Last[0].addr")
	sector, _ := dumpInt(k, "Last[0].sector")
	ln, _ := dumpInt(k, "Last[0].len")
	t.Logf("addr=%#x sector=%d want_sector=%d len=%d", uint64(addr), sector, want, ln)
	if addr != 0 {
		t.Errorf("kaddr-zero: Last[0].addr = %#x, want 0 (the mutation did not take)", uint64(addr))
	}
	if ln != 4096 || sector != want {
		t.Errorf("kaddr-zero: len %d sector %d (want 4096 and %d) — the pointee reads must not change", ln, sector, want)
	}
}
