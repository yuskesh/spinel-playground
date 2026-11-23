package main

import (
	"path/filepath"
	"strings"
	"testing"
)

// E147 の H4 / H5 (P028 — tracepoint の str の field の tool。mountsnoop の selftest は E136 の TestBccSelftestMountsnoop — path の照らしを足した)。
func TestBccSelftestOpensnoop(t *testing.T) { bccSelftest(t, "bcc/opensnoop") }
func TestBccSelftestStatsnoop(t *testing.T) { bccSelftest(t, "bcc/statsnoop") }

// TestBccSelftestTrace は E147 の H4 / H5 (trace — 実用の形は --pid が必須なので bccSelftest の形でなく、--pid 1 (init) の 1000 ms)。
func TestBccSelftestTrace(t *testing.T) {
	requireUnverified(t) // E046
	cfg, _ := defaultConfig()
	d := t.TempDir()
	src := bccSource(t, d, "bcc/trace")
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "trace")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe, "--selftest")
	t.Log(out)
	if !strings.Contains(out, "selftest ok") {
		t.Errorf("--selftest: want %q in the output", "selftest ok")
	}
	t.Log(feed(t, true, "", exe, "--pid", "1", "--duration-ms", "1000"))
}
