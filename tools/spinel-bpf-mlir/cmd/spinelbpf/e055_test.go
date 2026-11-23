package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// E055 の試験 (P012 の例): examples/ringworker — worker の Thread が ring を読み (持ち主)、main が kernel の数を出し、drain の最中の close の STATE で
// join してやり直す。

var ringworkerArtefacts = []string{"ringworker.mlir", "ringworker.schema.json", "ringworker.maps.json", "ringworker.domain.json", "ringworker.bpf.o",
	"ringworker.compile_warnings.txt", "ringworker_embed.S", "ringworker_embed.o"}

// TestRingworkerArtefacts は E055 の H1: 2 回の build の生成物が commit 済みの物と byte 同じ。
func TestRingworkerArtefacts(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "ringworker", "ringworker.rb"))
	for i := 0; i < 2; i++ {
		d := t.TempDir()
		src := filepath.Join(d, "ringworker.rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		for _, f := range ringworkerArtefacts {
			got, _ := os.ReadFile(filepath.Join(d, f))
			want, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "ringworker", f))
			if err != nil || !bytes.Equal(got, want) {
				t.Errorf("build %d: %s differs from the committed one (%v)", i, f, err)
			}
		}
	}
}

// TestRingworkerSelftestHost は E055 の H1〜H3 (host、root): 実行 file は threaded、`--selftest 40` で worker の数 = kernel の数 = 10 × 4、
// close は refused → join → close か、先に通る経路 (どちらも selftest ok)。
func TestRingworkerSelftestHost(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "ringworker", "ringworker.rb"))
	src := filepath.Join(d, "ringworker.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "ringworker")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	nm, _ := exec.Command("nm", exe).Output()
	if !strings.Contains(string(nm), " sp_sched_init\n") {
		t.Errorf("the example uses Thread — want the threaded runtime")
	}
	out := feed(t, true, "", exe, "--selftest", "40")
	t.Log(out)
	for _, w := range []string{"kernel counts: ipv4=10 ipv6=10 arp=10 other=10 drops=0 (worker read 40)", "worker counts: ipv4=10 ipv6=10 arp=10 other=10 late=0", "selftest ok"} {
		if !strings.Contains(out, w+"\n") {
			t.Errorf("want %q", w)
		}
	}
	if !strings.Contains(out, "close refused while the worker drained") && !strings.Contains(out, "close went first") {
		t.Errorf("the close path is not reported")
	}
}
