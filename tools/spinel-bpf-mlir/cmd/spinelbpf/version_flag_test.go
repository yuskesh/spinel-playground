package main

import (
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestVersionFlag は E090 の H2: `spinelbpf --version` (と `version`) の形 — 1 行目は版と build の commit (vcs の stamp — 12 桁と汚れていれば +dirty)、
// 続く行は bpf-mlir の require の版・bml / spinel の pin・ebpf-compile の版。stamp の無い build (`-buildvcs=false`) は `(commit unknown)`。
func TestVersionFlag(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	d := t.TempDir()
	want := versionFlagWant // E161 追補 2: 形ごとの期待 (form_{dev,public}_test.go)
	for _, c := range []struct {
		name, flag, commit string
	}{{"vcs", "-buildvcs=true", `\(commit [0-9a-f]{12}(\+dirty)?\)`}, {"novcs", "-buildvcs=false", `\(commit unknown\)`}} {
		bin := filepath.Join(d, c.name)
		b := exec.Command(cfg.Go, append(append([]string{"build", c.flag}, formBuildArgs...), "-o", bin, "./cmd/spinelbpf")...)
		b.Dir = cfg.Repo
		if o, err := b.CombinedOutput(); err != nil {
			t.Fatalf("%s: %v\n%s", c.name, err, o)
		}
		for _, arg := range []string{"--version", "version"} {
			o, err := exec.Command(bin, arg).Output()
			if err != nil || !want.Match(o) || !regexp.MustCompile(c.commit).Match(o) {
				t.Errorf("%s %s (err %v):\n%s", c.name, arg, err, o)
			}
		}
	}
	// build の既存の使い方は変わらない (引数の無い時は usage で 2)
	var so, se strings.Builder
	if rc := run(nil, &so, &se); rc != 2 || !strings.Contains(se.String(), "spinelbpf --version") {
		t.Errorf("run(): rc %d stderr %q", rc, se.String())
	}
}
