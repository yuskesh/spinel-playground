//go:build spinelbpf_mutation

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestHookRecordMultiCPU は E022 の H4 (root): hook no-rmw で SB019 を外した mc.rb を全ての CPU で同時に test run — atomic_add の n は数え落とさず、
// load / add / store の m は数え落とす。1 CPU (repeat 同じ・CPU を 1 つに固定) では両方が同じ (単一の test run では見えない — go-bpf-mlir E023)。
func TestHookRecordMultiCPU(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	if os.Getenv("SPINELBPF_NO_ROOT") == "1" {
		t.Skip("SPINELBPF_NO_ROOT=1")
	}
	cfg, _ := defaultConfig()
	t.Setenv("SPINELBPF_MUTATION", "no-rmw")
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "rec", "mc.rb"))
	src := filepath.Join(d, "mc.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	os.Unsetenv("SPINELBPF_MUTATION")
	runner := filepath.Join(d, "mcrun")
	gb := exec.Command(cfg.Go, "build", "-o", runner, "./cmd/spinelbpf/testdata/mcrun")
	gb.Dir = cfg.Repo
	gb.Env = append(os.Environ(), "GOFLAGS=-mod=mod")
	if o, err := gb.CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, o)
	}
	out, err := sudoCmd(t, runner, filepath.Join(d, "mc.bpf.o"), "200000").CombinedOutput()
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	t.Logf("all CPUs: %s", strings.TrimSpace(string(out)))
	var cpus, repeat, want, n, m, lost int
	var pct float64
	if _, err := fmt.Sscanf(strings.TrimSpace(string(out)), "cpus=%d repeat=%d want=%d n=%d m=%d lost=%d (%f%%)", &cpus, &repeat, &want, &n, &m, &lost, &pct); err != nil {
		t.Fatalf("unreadable: %v", err)
	}
	if n != want {
		t.Errorf("atomic_add lost counts: n=%d want %d", n, want)
	}
	if cpus > 1 && m >= n {
		t.Errorf("the load / add / store member did not lose counts on %d CPUs (m=%d n=%d) — not predicted", cpus, m, n)
	}
	one, err := sudoCmd(t, "taskset", "-c", "0", runner, filepath.Join(d, "mc.bpf.o"), "200000").CombinedOutput()
	t.Logf("one CPU (taskset 0 — the goroutines' affinity fails on other CPUs?): err=%v %s", err, strings.TrimSpace(string(one)))
}
