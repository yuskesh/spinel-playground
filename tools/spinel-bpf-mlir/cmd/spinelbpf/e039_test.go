package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// E039 の試験: per-CPU の多 CPU と差動 (P009 §4)。

type pcpuOut struct {
	cpus, repeat, nominal int
	n, m, h               []int
	sumN, sumM, sumH      int
}

func ints(s string) []int {
	if s == "-" {
		return nil
	}
	var out []int
	for _, x := range strings.Split(s, ",") {
		v, _ := strconv.Atoi(x)
		out = append(out, v)
	}
	return out
}

// pcpuMC は testdata/percpu/<name>.rb を build し (hook は変異の対照)、mcrun の percpu の mode を root で走らせる (固定に失敗すれば runner が止まる)。
func pcpuMC(t *testing.T, name, hook string, repeat int) pcpuOut {
	t.Helper()
	if os.Getenv("SPINELBPF_NO_ROOT") == "1" {
		t.Skip("SPINELBPF_NO_ROOT=1")
	}
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "percpu", name+".rb"))
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
	out, err := sudoCmd(t, runner, "percpu", filepath.Join(d, name+".bpf.o"), fmt.Sprint(repeat)).CombinedOutput()
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	line := strings.TrimSpace(string(out))
	t.Logf("%s %s: %s", name, hook, line)
	var o pcpuOut
	var ns, ms, hs string
	if _, err := fmt.Sscanf(line, "cpus=%d repeat=%d nominal=%d n=%s sum_n=%d m=%s sum_m=%d h=%s sum_h=%d", &o.cpus, &o.repeat, &o.nominal, &ns, &o.sumN, &ms, &o.sumM, &hs, &o.sumH); err != nil {
		t.Fatalf("unreadable: %v", err)
	}
	o.n, o.m, o.h = ints(ns), ints(ms), ints(hs)
	return o
}

// TestPercpuMultiCPU は E039 の H1 (host、root — 5 回): 全ての CPU に固定した thread (getcpu で確かめた) の repeat 1 の run で、
// per-CPU の record の CPU ごとの n = その CPU の実行の数・m = 2 倍、per-CPU の hash の key 3 の CPU ごとの値 = その CPU の実行の数、和 = 名目。
func TestPercpuMultiCPU(t *testing.T) {
	for i := 0; i < 5; i++ {
		o := pcpuMC(t, "mc", "", 20000)
		if o.sumN != o.nominal || o.sumM != 2*o.nominal || o.sumH != o.nominal {
			t.Errorf("sums n %d m %d h %d, nominal %d", o.sumN, o.sumM, o.sumH, o.nominal)
		}
		for cpu := 0; cpu < o.cpus; cpu++ {
			if o.n[cpu] != o.repeat || o.m[cpu] != 2*o.repeat || o.h[cpu] != o.repeat {
				t.Errorf("CPU %d: n %d m %d h %d, want %d each (m twice)", cpu, o.n[cpu], o.m[cpu], o.h[cpu], o.repeat)
			}
		}
	}
}

func tPcpuSrc() string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "percpu", "t_pcpu.rb")
}

// tPcpuScript は t_pcpu の表 (期待の値を持たない)。行は `echo <label>` で始まる。
func tPcpuScript() string {
	var b strings.Builder
	step := func(prog string, k0, k1, v int64) {
		fmt.Fprintf(&b, "poke In 0 %d\npoke In 1 %d\npoke In 3 %d\nrun %s\ndump\n", k0, k1, v, prog)
	}
	row := func(label string) { fmt.Fprintf(&b, "echo %s\nreset\n", label) }
	row("add")
	for _, x := range []int64{1, 2, 65535, 100} {
		step("t_add", 0, x, 0)
	}
	for _, x := range []int64{7, 65535} {
		step("t_add", 1, x, 0)
	}
	row("poke_then_add") // user 空間の put (slot 0) と program の加算
	b.WriteString("poke PI 0 1000\npoke PI 1 -5\n")
	step("t_add", 0, 3, 0)
	step("t_add", 1, 4, 0)
	row("h_ops") // per-CPU の hash の status (hash と同じ表の形 — 値は今の CPU の slot)
	for _, op := range []int64{1, 1, 2, 0, 4, 4, 3, 3, 2} {
		step("t_h", op, 7, 32868)
	}
	row("h_full")
	for _, k := range []int64{1, 2, 3, 4, 5} {
		step("t_h", 1, k, 32769)
	}
	step("t_h", 0, 3, 65535)
	step("t_h", 4, 6, 32769)
	step("t_h", 4, 3, 32769)
	return b.String()
}

// TestPercpuTable は E039 の H3 (host、root): t_pcpu の表で twin (Spinel)・kernel (taskset -c 0)・CRuby が byte 一致 (CPU ごとの和と 0 でない slot の数)、kernel の 0 でない slot の数は 1 以下。
func TestPercpuTable(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildHarnesses(t, tPcpuSrc())
	script := tPcpuScript()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, "taskset", "-c", "0", h.kernelBin)
	rb := crubyFeed(t, script, h)
	if d := ringDiff(tw, kn); d != "" {
		t.Errorf("twin / kernel: %s", d)
	}
	if d := ringDiff(tw, rb); d != "" {
		t.Errorf("twin / CRuby: %s", d)
	}
	t.Logf("%d lines", strings.Count(tw, "\n"))
	for _, l := range strings.Split(kn, "\n") {
		if i := strings.Index(l, " nz="); i >= 0 && l[i+4:] != "0" && l[i+4:] != "1" {
			t.Errorf("more than one non-zero slot on one pinned CPU: %s", l)
		}
	}
	if !strings.Contains(kn, "Out[0]=-7") || !strings.Contains(kn, "PR[0].a=65638") {
		t.Errorf("the kernel output lacks the full-table status or the summed member")
	}
}
