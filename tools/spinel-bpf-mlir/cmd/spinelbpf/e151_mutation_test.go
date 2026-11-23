//go:build spinelbpf_mutation

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// E151 の H6 (観測 — 予測しない): hook `argv-flat` (str_at [k+1] を present [k] の外 — program の直下 — に並べる) で compile が止まるかを記録する
// (止まれば「present の順を frontend が持つ」の根拠、通れば Edoc に名指し — どちらでも pass)。
func TestHookArgvFlat(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "argv-flat")
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(argvSrc("trace_argv"))
	src := filepath.Join(d, "trace_argv.rb")
	os.WriteFile(src, b, 0o644)
	_, err := Build(cfg, src)
	t.Logf("argv-flat: build error = %v", err)
}

// E151 の H6: hook `argv-index-shift` (index の literal を k+1 に) — kernel の event の index が双子 (k) と違う (意図した理由 — slot の番号の取り違え)。
func TestHookArgvIndexShift(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "argv-index-shift")
	h := buildHarnesses(t, argvSrc("trace_argv"))
	k, w := argvDiff(t, h, "a2")
	t.Logf("kernel step 2 %v", ringLines(k[2]))
	t.Logf("twin   step 2 %v", ringLines(w[2]))
	for i := 0; i < 3; i++ {
		wantLines(t, k[2], fmt.Sprintf("Events#%d.index=%d", i, i+1))
		wantLines(t, w[2], fmt.Sprintf("Events#%d.index=%d", i, i))
	}
}
