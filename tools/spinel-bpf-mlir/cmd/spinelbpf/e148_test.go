package main

import (
	"path/filepath"
	"strings"
	"testing"
)

// E148 の H4 / H5 (P028 — current_comm と kprobe の ptr の値の tool)。
func TestBccSelftestCapable(t *testing.T) { bccSelftest(t, "bcc/capable") }
func TestBccSelftestFilelife(t *testing.T) { bccSelftest(t, "bcc/filelife") }

// TestBccSelftestBiolatency は E148 の H4 / H5 (biolatency — 追補 2: selftest の file の dir を --dir の引数で渡す。sudo は TMPDIR を落とし、
// /tmp の tmpfs の fsync は block I/O を出さない — repo の build/tmp (block device の上) を渡す)。
func TestBccSelftestBiolatency(t *testing.T) {
	requireUnverified(t) // E046
	cfg, _ := defaultConfig()
	d := t.TempDir()
	src := bccSource(t, d, "bcc/biolatency")
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "biolatency")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe, "--selftest", "--dir", filepath.Join(repoRoot(), "build", "tmp"))
	t.Log(out)
	if !strings.Contains(out, "selftest ok") {
		t.Errorf("--selftest: want %q in the output", "selftest ok")
	}
	t.Log(feed(t, true, "", exe, "--duration-ms", "1000"))
}
