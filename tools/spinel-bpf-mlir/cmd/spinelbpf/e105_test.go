package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestBuildRemovesWork is E105's H1: after a successful build no directory of Spinel's analysis work remains;
// with SPINELBPF_KEEP_WORK=1 it remains, and a failed build keeps it for diagnosis (one gate run left about 60 GB — at the bpf-mlir coordinator's request).
func TestBuildRemovesWork(t *testing.T) {
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	exists := func(p string) bool { _, err := os.Stat(p); return err == nil }
	t.Run("success", func(t *testing.T) {
		p := copyExample(t, t.TempDir())
		if _, err := Build(cfg, p); err != nil {
			t.Fatal(err)
		}
		if w := workDir(cfg.Repo, p); exists(w) {
			t.Errorf("the work directory remained after a successful build: %s", w)
		}
	})
	t.Run("keep", func(t *testing.T) {
		t.Setenv("SPINELBPF_KEEP_WORK", "1")
		p := copyExample(t, t.TempDir())
		if _, err := Build(cfg, p); err != nil {
			t.Fatal(err)
		}
		w := workDir(cfg.Repo, p)
		if !exists(filepath.Join(w, "typing")) {
			t.Errorf("SPINELBPF_KEEP_WORK=1 did not keep %s", w)
		}
		os.RemoveAll(w)
	})
	t.Run("failure", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "bad.rb")
		os.WriteFile(p, []byte("require \"bpf\"\n\ndef prog(ctx)\n  if 1\n  end\n  BPF::XDP_PASS\nend\nBPF.xdp :prog\n"), 0o644)
		if _, err := Build(cfg, p); err == nil || !strings.Contains(err.Error(), "SB005") {
			t.Fatalf("want SB005, got %v", err)
		}
		w := workDir(cfg.Repo, p)
		if !exists(w) {
			t.Errorf("the work directory of a failed build was removed: %s", w)
		}
		os.RemoveAll(w)
	})
}
