//go:build spinelbpf_mutation

package main

import (
	"strings"
	"testing"
)

// E112 の H7: hook `uretval-sext` (uretprobe の u32 の戻り値を i64 に広げる所を符号の拡張に — 試験の build だけ) — `greet 4294967290 hello`
// (4294967295) の kernel の Rets[3] が −1 になり、双子 (4294967295) と違う (意図した理由 — 符号の拡張の取り違え)。
func TestHookUretvalSext(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "uretval-sext")
	h := buildHarnesses(t, uprobeSrc("uret_ints"))
	k, w, _ := uretDiff(t, h)
	t.Log(k)
	if !strings.Contains(k, "Rets[3]=-1\n") {
		t.Errorf("the mutated kernel should sign-extend greet's 4294967295 to −1:\n%s", k)
	}
	if !strings.Contains(w, "Rets[3]=4294967295\n") {
		t.Errorf("the twin keeps 4294967295:\n%s", w)
	}
}
