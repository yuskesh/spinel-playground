package main

import (
	"os"
	"os/exec"
	"regexp"
	"strings"
	"testing"
	"time"
)

// TestRootCallsUseLock is E106's H1: no tracked Go or shell file runs sudo outside bpf-mlir's root lock
// (Go uses sudoCmd, the shell the rsudo of scripts/lib/rootlock.sh — at the bpf-mlir coordinator's request, 2026-10-04). Each run inside the lock is marked by a `rootlock:ok` line.
// shell で `sudo …` を書く file (tutorial の綴りの tutorial-run) は sudo を rsudo に置き換える関数を持つこと。
func TestRootCallsUseLock(t *testing.T) {
	out, err := exec.Command("git", "-C", repoRoot(), "ls-files", "--", "*.go", "*.sh").Output()
	if err != nil {
		t.Fatal(err)
	}
	goRe := regexp.MustCompile(`exec\.Command\("sudo"`)
	shRe := regexp.MustCompile(`(^|[;&|({]\s*|\bthen\s+|\bdo\s+|\belse\s+)(command\s+)?sudo\s`)
	var bad []string
	for _, f := range strings.Fields(string(out)) {
		if strings.HasPrefix(f, "third_party/") || strings.HasPrefix(f, "docs/") {
			continue
		}
		b, err := os.ReadFile(repoRoot() + "/" + f)
		if err != nil {
			t.Fatal(err)
		}
		isSh := strings.HasSuffix(f, ".sh")
		wraps := strings.Contains(string(b), `sudo() { rsudo "$@"; }`)
		for i, l := range strings.Split(string(b), "\n") {
			if strings.Contains(l, "rootlock:ok") {
				continue
			}
			s := strings.TrimSpace(l)
			if !isSh {
				if !strings.HasPrefix(s, "//") && goRe.MatchString(l) {
					bad = append(bad, f+":"+itoa(i+1))
				}
				continue
			}
			if strings.HasPrefix(s, "#") {
				continue
			}
			if m := shRe.FindStringSubmatch(s); m != nil && (m[2] != "" || strings.Contains(s, "sudo -n") || !wraps) {
				bad = append(bad, f+":"+itoa(i+1))
			}
		}
	}
	if len(bad) > 0 {
		t.Errorf("%d root calls outside the bpf-mlir root lock:\n%s", len(bad), strings.Join(bad, "\n"))
	}
}

// TestRootLockWaits は E106 の機構: lock を他が持つ間は sudoCmd の root の呼び出しが待ち、放した後に走る。
// 共通の lock は持たない (bpf-mlir の root の段を止めない) — SPINELBPF_ROOT_LOCK で一時の file を lock にする。
func TestRootLockWaits(t *testing.T) {
	if os.Getenv("SPINELBPF_NO_ROOT") == "1" {
		t.Skip("SPINELBPF_NO_ROOT=1")
	}
	l := t.TempDir() + "/root.lock"
	if err := os.WriteFile(l, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SPINELBPF_ROOT_LOCK", l)
	hold := exec.Command("flock", l, "sleep", "2")
	if err := hold.Start(); err != nil {
		t.Fatal(err)
	}
	defer hold.Wait()
	time.Sleep(300 * time.Millisecond) // flock(1) が lock を取るまで
	start := time.Now()
	if out, err := sudoCmd(t, "true").CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if d := time.Since(start); d < 1500*time.Millisecond {
		t.Errorf("the root call ran after %v while another held the lock for 2 s", d)
	}
}

// TestRootLockTimeout は E108 の H1: lock を他が持ち続ける間、待ちの秒 (SPINELBPF_ROOT_LOCK_WAIT) で sudoCmd の呼び出しが rc 125 と lock の path を
// 名指す文で終わり、自分の flock の子が残らない (go test の timeout で flock の子が残った E107 の形を無くす)。共通の lock は持たない。
func TestRootLockTimeout(t *testing.T) {
	if os.Getenv("SPINELBPF_NO_ROOT") == "1" {
		t.Skip("SPINELBPF_NO_ROOT=1")
	}
	l := t.TempDir() + "/root.lock"
	if err := os.WriteFile(l, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SPINELBPF_ROOT_LOCK", l)
	t.Setenv("SPINELBPF_ROOT_LOCK_WAIT", "2")
	hold := exec.Command("flock", l, "sleep", "8")
	if err := hold.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { hold.Process.Kill(); hold.Wait() }()
	time.Sleep(300 * time.Millisecond)
	start := time.Now()
	cmd := sudoCmd(t, "true")
	out, err := cmd.CombinedOutput()
	d := time.Since(start)
	ee, ok := err.(*exec.ExitError)
	if !ok || ee.ExitCode() != 125 || !strings.Contains(string(out), l) || d > 5*time.Second {
		t.Fatalf("want rc 125 naming %s within 5 s, got err=%v after %v:\n%s", l, err, d, out)
	}
	if o, _ := exec.Command("pgrep", "-f", "flock .*"+l+" .*sudo").Output(); len(o) > 0 {
		t.Errorf("a flock child is left waiting on %s: %s", l, o)
	}
	t.Logf("rc 125 after %v: %s", d.Round(100*time.Millisecond), strings.TrimSpace(string(out)))
}
