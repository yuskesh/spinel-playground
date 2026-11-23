package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E054 の試験 (P013 の例): examples/pollwatch — kprobe (do_sys_poll の nfds) と fentry (helper だけ)。

var pollwatchArtefacts = []string{"pollwatch.mlir", "pollwatch.schema.json", "pollwatch.maps.json", "pollwatch.domain.json", "pollwatch.bpf.o",
	"pollwatch.compile_warnings.txt", "pollwatch_embed.S", "pollwatch_embed.o"}

// TestPollwatchArtefacts は E054 の H1: 2 回の build の生成物が commit 済みの物と byte 同じ。
func TestPollwatchArtefacts(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "pollwatch", "pollwatch.rb"))
	for i := 0; i < 2; i++ {
		d := t.TempDir()
		src := filepath.Join(d, "pollwatch.rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		for _, f := range pollwatchArtefacts {
			got, _ := os.ReadFile(filepath.Join(d, f))
			want, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "pollwatch", f))
			if err != nil || !bytes.Equal(got, want) {
				t.Errorf("build %d: %s differs from the committed one (%v)", i, f, err)
			}
		}
	}
}

// TestPollwatchSelftestHost は E054 の H2 (host、root): 自分の tgid に濾して poll 6 回 (nfds 3 × 4 + 5 × 2 = 22) と tracing の test run 10 回。
func TestPollwatchSelftestHost(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "pollwatch", "pollwatch.rb"))
	src := filepath.Join(d, "pollwatch.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "pollwatch")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe, "--selftest")
	t.Log(out)
	if !strings.Contains(out, "polls=6 nfds=22 tests=10 (test run thread differs)\nselftest ok") {
		t.Errorf("selftest failed")
	}
}
