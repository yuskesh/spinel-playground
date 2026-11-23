//go:build spinelbpf_mutation

package main

import (
	"testing"
)

// E115 の H7: hook `ksyscall-swap34` (op の syscall の引数の番号の 3 と 4 を入れ替える — 両方とも宣言の u64 なので schema と sysarg の照合を
// 通る) — H4 の kernel の Out[2]=7・Out[3]=6 になり、双子 (6・7) と違う (意図した理由 — syscall の引数の番号の取り違え、dx と r10)。
func TestHookKsyscallSwap34(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "ksyscall-swap34")
	h := buildHarnesses(t, ksSrc())
	k, w := ksAttachDiff(t, h, true)
	t.Log(k)
	wantLines(t, k, "Out[0]=3", "Out[2]=7", "Out[3]=6")
	wantLines(t, w, ksWant...)
}
