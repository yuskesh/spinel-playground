package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// E043 の試験: 既定の C の loader (bml) の実行 file に Go の runtime が無いこと (P010 §3 — host、root)。

// TestGoRuntimeRemoved は E043 の H7: 既定の loader で link した実行 file に Go の runtime の symbol が 0、load の後に捕まえる signal は Spinel の 2 つ (7・11) だけ、
// thread は 1 つ、load の後の深い再帰は SystemStackError で rescue され process が続く (Go を link した E001 は SIGSEGV)。
func TestGoRuntimeRemoved(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	run := func(name string) string {
		d := t.TempDir()
		b, err := os.ReadFile(filepath.Join(repoRoot(), "docs", "experiments", "results", "E043", name+".rb"))
		if err != nil {
			t.Fatal(err)
		}
		src := filepath.Join(d, name+".rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		exe := filepath.Join(d, name)
		if err := Link(cfg, src, exe); err != nil {
			t.Fatal(err)
		}
		syms, _ := exec.Command("nm", exe).Output()
		if n := strings.Count(string(syms), " runtime."); n != 0 {
			t.Errorf("%s: %d Go runtime symbols", name, n)
		}
		return feed(t, true, "", exe)
	}
	out := run("sigcgt")
	t.Log(out)
	if !strings.Contains(out, "SigCgt=[7, 11]") || !strings.Contains(out, "Threads: 1") {
		t.Errorf("want only Spinel's handlers (7, 11) and one thread")
	}
	out = run("deep")
	t.Log(out)
	if !strings.Contains(out, "rescued SystemStackError") || !strings.Contains(out, "after counts=1") {
		t.Errorf("want SystemStackError rescued after the load")
	}
}
