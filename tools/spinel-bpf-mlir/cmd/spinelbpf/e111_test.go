package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E111 の試験 (P026 — kretprobe の戻り値): 生成物 (H1)・双子の smoke (H3)・kernel と双子の 2 段の差動と濾しの対照 (H4・H5 — root)・
// attach の kind の取り違え (H6 — root)。負の例 (H2) は internal/frontend の testdata/neg の kret_*.rb と kprobe_ret.rb (TestNegative)。

func kretSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_kretprobe.rb")
}

// TestKretprobeArtefacts は H1 (と追補 1): .mlir の program の行と probe.retval、schema の program、ELF の requirements の版 9 と付随の行。
func TestKretprobeArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(kretSrc())
	src := filepath.Join(d, "trace_kretprobe.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "trace_kretprobe.mlir"))
	for _, w := range []string{`ebpf.program @on_ret_poll "kretprobe" attach "do_sys_poll" arch "x86_64"`, `ebpf.probe.retval %ctx : !ebpf.ctx<"kretprobe"> -> i32`} {
		if !strings.Contains(string(m), w) {
			t.Errorf(".mlir lacks %q", w)
		}
	}
	s, _ := os.ReadFile(filepath.Join(d, "trace_kretprobe.schema.json"))
	if !strings.Contains(string(s), `"kind": "kretprobe"`) || !strings.Contains(string(s), `"attach_target": "do_sys_poll"`) || !strings.Contains(string(s), `"arch": "x86_64"`) || strings.Contains(string(s), `"params"`) {
		t.Errorf("schema program: want kind kretprobe, attach_target, arch and no params:\n%s", s)
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "trace_kretprobe.bpf.o"))
	for _, w := range []string{"ebpf-requirements 9\n", "attach\ton_ret_poll\tkretprobe\tdo_sys_poll\n", "arch\ton_ret_poll\tx86_64\n", "ctxfield\ton_ret_poll\tpt_regs\tax\t80\t8\n"} {
		if !strings.Contains(string(r), w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
	if strings.Contains(string(r), "kprobearg") {
		t.Errorf("a kretprobe has no kprobearg row:\n%s", r)
	}
}

// TestKretprobeTwinSmoke は H3: 双子の ret=-14 を 3 回・ret=0 を 1 回 → Rets[0]=0・Rets[1]=4・Rets[2]=-42 (Filter の tgid のときだけ)。
func TestKretprobeTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_kretprobe")
	tid := "18219251273881" // tgid 4242 << 32 | tid 4249
	out := feed(t, false, "reset\npoke Filter 0 4242\ntask "+tid+"\nrun on_ret_poll ret=-14\nrun on_ret_poll ret=-14\nrun on_ret_poll ret=-14\nrun on_ret_poll ret=0\ndump\n", tw)
	wantLines(t, out, "Rets[0]=0", "Rets[1]=4", "Rets[2]=-42")
}

// kretDiff は kretprobe の 2 段の差動: kernel は poll(NULL, n, 0) (a2=n) を、双子は同じ tid の task で戻り値 (ret=) を。
func kretDiff(t *testing.T, h harnessSet, self bool, ns []int, rets []int) (kernel, twin string, tgid int64) {
	t.Helper()
	var ks strings.Builder
	ks.WriteString("reset\n")
	if self {
		ks.WriteString("pokeself Filter 0\n")
	} else {
		ks.WriteString("poke Filter 0 1\n") // tgid 1 (init) — 濾しの対照
	}
	ks.WriteString("self\n")
	for _, n := range ns {
		fmt.Fprintf(&ks, "run on_ret_poll a2=%d\n", n)
	}
	ks.WriteString("dump\n")
	kernel = feed(t, true, ks.String(), h.kernelBin)
	tgid, tids := traceKernel(t, kernel)
	if len(tids) != len(ns) {
		t.Fatalf("want %d tids, got %v:\n%s", len(ns), tids, kernel)
	}
	var ts strings.Builder
	ts.WriteString("reset\n")
	if self {
		fmt.Fprintf(&ts, "poke Filter 0 %d\n", tgid)
	} else {
		ts.WriteString("poke Filter 0 1\n")
	}
	for i, r := range rets {
		fmt.Fprintf(&ts, "task %d\nrun on_ret_poll ret=%d\n", tgid<<32|tids[i], r)
	}
	ts.WriteString("dump\n")
	twin = feed(t, false, ts.String(), h.twinBin)
	return
}

// TestKretprobeDifferential は H4 と H5 (root): own の tgid で絞った kernel の dump (poll の n = 3・4・0 → 戻り値 −14・−14・0) が双子と一致し
// Rets[1]=3 (他の process の poll を数えない — 厳密に自分の run の数)、Filter を tgid 1 にすると kernel も双子も数えない。
func TestKretprobeDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, kretSrc())
	k, w, _ := kretDiff(t, h, true, []int{3, 4, 0}, []int{-14, -14, 0})
	t.Log(k)
	sameDump(t, "kretprobe", k, w)
	for _, l := range []string{"Rets[0]=0", "Rets[1]=3", "Rets[2]=-28"} {
		if !strings.Contains(k, l+"\n") {
			t.Errorf("kernel: want %s", l)
		}
	}
	k, w, _ = kretDiff(t, h, false, []int{3, 4, 0}, []int{-14, -14, 0})
	t.Log(k)
	sameDump(t, "kretprobe filtered", k, w)
	if !strings.Contains(k, "Rets[1]=0\n") || !strings.Contains(k, "Rets[2]=0\n") {
		t.Errorf("kretprobe filtered: the kernel counted another tgid's polls:\n%s", k)
	}
}

// TestKretprobeAttachKind は H6 (root): kretprobe を kprobe として・kprobe を kretprobe として attach すると誤り、正しい kind は OK。
func TestKretprobeAttachKind(t *testing.T) {
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "trace", "kret_attach_kind.rb"))
	src := filepath.Join(d, "kret_attach_kind.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "kret_attach_kind")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe)
	t.Log(out)
	for _, w := range []string{"kretprobe as kretprobe kind=OK", "detached"} {
		if !strings.Contains(out, w+"\n") {
			t.Errorf("want %q", w)
		}
	}
	if !strings.Contains(out, "kretprobe as kprobe kind=SpinelBPF::") || !strings.Contains(out, "kprobe as kretprobe kind=SpinelBPF::") {
		t.Errorf("attaching across kprobe / kretprobe must fail loudly")
	}
}
