package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// E087 の試験 (P021): tp_btf の双子と harness (部 1 — attach に依らない)。

// buildTwinOnly は source の双子の harness だけを build する (kernel の harness は attach_tp_btf を持つ bml の pin の後 — 部 2)。
func buildTwinOnly(t *testing.T, src string) (string, *frontend.Result, string) {
	t.Helper()
	cfg, _ := defaultConfig()
	text, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	sp := frontend.Spinel{Bin: cfg.Spinel, LibDir: filepath.Join(cfg.Repo, "ruby", "lib")}
	res, err := frontend.Analyze(sp, t.TempDir(), src, string(text))
	if err != nil || res.Diags.Blocking() {
		t.Fatalf("analyze: %v %v", err, res.Diags)
	}
	tw, err := frontend.TwinHarness(string(text), res)
	if err != nil {
		t.Fatal(err)
	}
	td := t.TempDir()
	base := filepath.Base(src)
	os.WriteFile(filepath.Join(td, base), []byte(tw), 0o644)
	bin := filepath.Join(td, "twin")
	c := exec.Command(cfg.Spinel, "-I", filepath.Join(cfg.Repo, "ruby", "lib", "native"), base, "-o", bin)
	c.Dir, c.Env = td, append(os.Environ(), "TMPDIR="+td)
	if o, err := c.CombinedOutput(); err != nil {
		t.Fatalf("building the twin harness: %v\n%s\n%s", err, o, tw)
	}
	kh, err := frontend.KernelHarness(string(text), res)
	if err != nil {
		t.Fatal(err)
	}
	return bin, res, kh
}

func tFork() string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "tpbtf", "t_fork.rb")
}

// TestTpBtfTwin は E087 の H1・H2 (部 1): 双子の run が与えた struct の member と整数の引数で program を走らせ、Cfg[0] が親の tgid と等しい時だけ
// Out に子の pid・tgid。整数の引数は宣言の幅で切れる (u8 に 300 → 44)。宣言に無い名前は止まる。kernel の harness の生成は attach_tp_btf と fork を持つ。
func TestTpBtfTwin(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	bin, _, kh := buildTwinOnly(t, tFork())
	out := feed(t, false, "reset\npoke Cfg 0 77\nrun on_fork a0.tgid=77 a1.pid=1234 a1.tgid=1234\nrun on_fork a0.tgid=78 a1.pid=5 a1.tgid=5\ndump\nrun on_fork a1.flags=1\n", bin)
	for _, w := range []string{"Out[0]=1\n", "Out[1]=1234\n", "Out[2]=1234\n", "err=RuntimeError\n"} {
		if !strings.Contains(out, w) {
			t.Errorf("H1: want %q in the twin output:\n%s", w, out)
		}
	}
	for _, w := range []string{`_h_obj.attach_tp_btf("on_fork")`, `_h_cmd == "fork"`, "HTrace.h_fork"} {
		if !strings.Contains(kh, w) {
			t.Errorf("H2: the kernel harness lacks %q", w)
		}
	}
	// 整数の引数の幅 (tpbtf_switch — preempt は u8)
	sw, _, _ := buildTwinOnly(t, filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "tpbtf_switch.rb"))
	so := feed(t, false, "reset\nrun on_switch a0=300 a2.pid=9 a3=7\ndump\n", sw)
	for _, w := range []string{"Seen[0]=44\n", "Seen[1]=7\n", "Seen[2]=9\n"} {
		if !strings.Contains(so, w) {
			t.Errorf("H1: want %q in the switch twin output:\n%s", w, so)
		}
	}
	t.Logf("fork twin:\n%s\nswitch twin:\n%s", out, so)
}
