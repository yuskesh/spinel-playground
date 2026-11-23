package main

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// E136 の試験 (P027): bcc の tool の root の selftest — 共有の器は e133_test.go。

// E136 の H4 / H5。
func TestBccSelftestKillsnoop(t *testing.T)  { bccSelftest(t, "bcc/killsnoop") }
func TestBccSelftestSetuids(t *testing.T)    { bccSelftest(t, "bcc/setuids") }
func TestBccSelftestSyncsnoop(t *testing.T)  { bccSelftest(t, "bcc/syncsnoop") }
func TestBccSelftestExitsnoop(t *testing.T)  { bccSelftest(t, "bcc/exitsnoop") }
func TestBccSelftestMountsnoop(t *testing.T) { bccSelftest(t, "bcc/mountsnoop") }

// TestBccDecodeExitsnoop is the test before E136's retake (no root — the bpf-mlir coordinator's i773): exitsnoop's --decode-check reads the byte sequence of the Events layout
// flat with the library's read_member (the same form as the ring read) and checks the event's reading (comm's 16 bytes, the pid and tgid indices).
func TestBccDecodeExitsnoop(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	d := t.TempDir()
	src := bccSource(t, d, "bcc/exitsnoop")
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "exitsnoop")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command(exe, "--decode-check").CombinedOutput()
	t.Log(string(out))
	if err != nil || !strings.Contains(string(out), "decode ok") {
		t.Errorf("--decode-check: %v", err)
	}
}
