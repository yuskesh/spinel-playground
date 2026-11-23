package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// E035 の試験: add_or_init と多 CPU (P008 §5)。

type hashMCOut struct {
	cpus, repeat, nominal int
	stat                  [5]int
	counts, small         int
}

// hashMC は testdata/hash/<name>.rb を build し (hook は変異の対照 — 試験の build だけで効く)、mcrun の hash の mode を root で走らせる (one は 1 CPU に固定)。
func hashMC(t *testing.T, name, hook string, repeat int, one bool) hashMCOut {
	t.Helper()
	if os.Getenv("SPINELBPF_NO_ROOT") == "1" {
		t.Skip("SPINELBPF_NO_ROOT=1")
	}
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "hash", name+".rb"))
	src := filepath.Join(d, name+".rb")
	os.WriteFile(src, b, 0o644)
	if hook != "" {
		t.Setenv("SPINELBPF_MUTATION", hook)
	}
	_, err := Build(cfg, src)
	os.Unsetenv("SPINELBPF_MUTATION")
	if err != nil {
		t.Fatal(err)
	}
	runner := filepath.Join(d, "mcrun")
	gb := exec.Command(cfg.Go, "build", "-o", runner, "./cmd/spinelbpf/testdata/mcrun")
	gb.Dir = cfg.Repo
	gb.Env = append(os.Environ(), "GOFLAGS=-mod=mod")
	if o, err := gb.CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, o)
	}
	args := []string{runner, "hash", filepath.Join(d, name+".bpf.o"), fmt.Sprint(repeat)}
	if one {
		args = append([]string{"taskset", "-c", "0"}, args...)
	}
	out, err := sudoCmd(t, args...).CombinedOutput()
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	t.Logf("%s %s one=%v: %s", name, hook, one, strings.TrimSpace(string(out)))
	var o hashMCOut
	if _, err := fmt.Sscanf(strings.TrimSpace(string(out)), "cpus=%d repeat=%d nominal=%d stat=%d,%d,%d,%d,%d counts=%d small=%d", &o.cpus, &o.repeat, &o.nominal, &o.stat[0], &o.stat[1], &o.stat[2], &o.stat[3], &o.stat[4], &o.counts, &o.small); err != nil {
		t.Fatalf("unreadable: %v", err)
	}
	return o
}

// checkConservation は H1〜H3 の等式。
func checkConservation(t *testing.T, o hashMCOut) {
	t.Helper()
	if o.counts != o.stat[0] || o.stat[0] != o.nominal || o.stat[1] != 0 {
		t.Errorf("H1: Σ Counts %d, executions %d, nominal %d, non-zero statuses %d", o.counts, o.stat[0], o.nominal, o.stat[1])
	}
	if o.small+o.stat[2]+o.stat[3] != o.stat[0] || o.stat[2] == 0 || o.stat[3] != 0 {
		t.Errorf("H2: Σ Small %d + E2BIG %d + other %d != executions %d (want E2BIG > 0 and other 0)", o.small, o.stat[2], o.stat[3], o.stat[0])
	}
	if o.stat[4] != 8 {
		t.Errorf("H3: %d successful inserts of the 8 keys, want exactly 8", o.stat[4])
	}
}

// TestHashMultiCPU は E035 の H1〜H3 (host、root — 全ての CPU、5 回) と H6 (1 CPU)。
func TestHashMultiCPU(t *testing.T) {
	for i := 0; i < 5; i++ {
		checkConservation(t, hashMC(t, "mc", "", 20000, false))
	}
	checkConservation(t, hashMC(t, "mc", "", 20000, true))
}
