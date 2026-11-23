package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// TestPacketHostLoad は E014 の H5 (root): packet の正の例の ELF が host の verifier に受理される (照合付きの load — 可変の offset と
// map の present の腕の中の外の window を含む)。kernel の harness を作り `reset` / `dump` だけを流す (load は起動の時 — 差動は E015 / E016)。
func TestPacketHostLoad(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	files, _ := filepath.Glob(filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "pkt_*.rb"))
	if len(files) < 4 {
		t.Fatalf("want the packet positives, got %v", files)
	}
	for _, src := range files {
		text, err := os.ReadFile(src)
		if err != nil {
			t.Fatal(err)
		}
		sp := frontend.Spinel{Bin: cfg.Spinel, LibDir: filepath.Join(cfg.Repo, "ruby", "lib")}
		res, err := frontend.Analyze(sp, t.TempDir(), src, string(text))
		if err != nil || res.Diags.Blocking() {
			t.Fatalf("analyze %s: %v %v", src, err, res.Diags)
		}
		kbin := buildKernelHarness(t, cfg, filepath.Base(src), string(text), res)
		out := feed(t, true, "reset\ndump\n", kbin)
		if strings.Contains(out, "err=") || !strings.Contains(out, "[0]=0") {
			t.Fatalf("%s: unexpected harness output\n%s", src, out)
		}
		t.Logf("%s: loaded on the host (%d dump lines)", filepath.Base(src), strings.Count(out, "\n"))
	}
}
