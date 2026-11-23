//go:build spinelbpf_mutation

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestHookLpmMutations は E121 の H6 (host、root): 変異の対照の検出器の列 — 各々で双子と kernel の出力が食い違い、最初の食い違いが意図した行に在り、
// その行の中身に印の文字列がある。lpm-shortest と lpm-full-overwrite は harness の双子 (最短一致・満杯の上書きを −ENOSPC)、lpm-plen24 は frontend の key の
// prefixlen (kernel の側の ELF だけが変わる)。
func TestHookLpmMutations(t *testing.T) {
	requireUnverified(t)
	script := tLpmScript()
	for _, m := range []struct {
		name, hook string
		row, line  string
	}{
		{"shortest (双子を最短一致に)", "lpm-shortest", "l_bounds", "lmatch="},
		{"plen24 (key の prefixlen を 24 に)", "lpm-plen24", "l_bounds", "Out[1]="},
		{"full-overwrite (満杯の上書きを −ENOSPC に)", "lpm-full-overwrite", "l_full", "lput="},
	} {
		t.Setenv("SPINELBPF_MUTATION", m.hook)
		h := buildHarnesses(t, lpmData("t_lpm.rb"))
		os.Unsetenv("SPINELBPF_MUTATION")
		tw := feed(t, false, script, h.twinBin)
		kn := feed(t, true, script, h.kernelBin)
		d := ringDiff(tw, kn)
		t.Logf("%s: %s", m.name, d)
		if d == "" || !strings.HasPrefix(d, "row "+m.row+" ") || !strings.Contains(d, "\""+m.line) {
			t.Errorf("%s: want the first difference at row %s on %q, got %q", m.name, m.row, m.line, d)
		}
	}
}

// TestHookLpmFlags は E121 追補 1 (host、root): flags の照合 — 変異の無い build は load と lpm_put が通り、埋め込みの宣言から flags を落とす (frontend の
// lpm-no-flags) と load が、SpinelBPF.decl から flags を落とした library の写しで link すると lpm_put が MapMismatch。
func TestHookLpmFlags(t *testing.T) {
	requireUnverified(t)
	cfg := lpmConfig(t)
	if out := feed(t, true, "", buildLpmProgram(t, "lpmflags", cfg)); out != "load ok\nput ok match=1\n" {
		t.Fatalf("the unmutated program: %q", out)
	}
	t.Setenv("SPINELBPF_MUTATION", "lpm-no-flags")
	exe := buildLpmProgram(t, "lpmflags", cfg)
	os.Unsetenv("SPINELBPF_MUTATION")
	if out := feed(t, true, "", exe); out != "load err=SpinelBPF::MapMismatch\n" {
		t.Errorf("embedded declaration without flags: %q", out)
	}
	// library の写し (ruby/lib — SpinelBPF.decl の lpm_trie の flags の行を消す) で link。写しの root には ruby/ だけを写し、Link が読む他のもの (版の照合の
	// index と submodule・build/tmp・packaging/needed.allow) は本物の repo への symlink — library の path だけが写しに向く (E121 追補 3)
	mut := t.TempDir()
	if o, err := exec.Command("cp", "-r", filepath.Join(cfg.Repo, "ruby"), mut).CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, o)
	}
	for _, n := range []string{".git", "third_party", "build", "packaging"} {
		if err := os.Symlink(filepath.Join(cfg.Repo, n), filepath.Join(mut, n)); err != nil {
			t.Fatal(err)
		}
	}
	lib := filepath.Join(mut, "ruby", "lib", "spinelbpf.rb")
	b, _ := os.ReadFile(lib)
	line := "      d = d + \",\\\"flags\\\":1\""
	if !strings.Contains(string(b), line) {
		t.Fatal("the decl's flags line is not in the library")
	}
	os.WriteFile(lib, []byte(strings.Replace(string(b), line, "      d = d + \"\"", 1)), 0o644)
	mcfg := cfg
	mcfg.Repo = mut
	if out := feed(t, true, "", buildLpmProgram(t, "lpmflags", cfg, mcfg)); out != "load ok\nput err=SpinelBPF::MapMismatch\n" {
		t.Errorf("SpinelBPF.decl without flags: %q", out)
	}
}
