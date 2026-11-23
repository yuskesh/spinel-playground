package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E053 の試験 (P013 — host、root): tracing の load・attach・test run と双子の差動 (2 段 — kernel の tid を双子の task に)。

// traceKernel は kernel の harness の出力から tgid と run ごとの tid を読む。
func traceKernel(t *testing.T, out string) (tgid int64, tids []int64) {
	t.Helper()
	for _, l := range strings.Split(out, "\n") {
		var v int64
		if _, err := fmt.Sscanf(l, "tgid=%d", &v); err == nil {
			tgid = v
		}
		var tid int64
		if _, err := fmt.Sscanf(l, "ret=0 tid=%d", &tid); err == nil {
			tids = append(tids, tid)
		}
	}
	if tgid == 0 {
		t.Fatalf("no tgid in the kernel harness output:\n%s", out)
	}
	return
}

// traceDumpLines は dump の行 (Map[k]=v / Map{k}=v)。
func traceDumpLines(out string) []string {
	var d []string
	for _, l := range strings.Split(out, "\n") {
		if (strings.Contains(l, "[") || strings.Contains(l, "{")) && strings.Contains(l, "]=") || strings.Contains(l, "}=") {
			d = append(d, l)
		}
	}
	return d
}

// traceDiff は 1 つの tracing の program の 2 段の差動: kernel の手順 (runs は run の行の引数の列) を走らせ、tid を双子の task に挟んで同じ手順を双子で。
func traceDiff(t *testing.T, name, prog string, runs []string, twinExtra string, filterSelf bool) (kernel, twin string, tgid int64) {
	t.Helper()
	h := buildHarnesses(t, filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", name+".rb"))
	var ks strings.Builder
	ks.WriteString("reset\n")
	if filterSelf {
		ks.WriteString("pokeself Filter 0\n")
	} else {
		ks.WriteString("poke Filter 0 1\n") // tgid 1 (init) — 濾しの対照
	}
	ks.WriteString("self\n")
	for _, r := range runs {
		fmt.Fprintf(&ks, "run %s %s\n", prog, r)
	}
	ks.WriteString("dump\n")
	kernel = feed(t, true, ks.String(), h.kernelBin)
	tgid, tids := traceKernel(t, kernel)
	if len(tids) != len(runs) {
		t.Fatalf("want %d tids, got %v:\n%s", len(runs), tids, kernel)
	}
	var ts strings.Builder
	ts.WriteString("reset\n")
	if filterSelf {
		fmt.Fprintf(&ts, "poke Filter 0 %d\n", tgid)
	} else {
		ts.WriteString("poke Filter 0 1\n")
	}
	for i, r := range runs {
		fmt.Fprintf(&ts, "task %d\nrun %s %s%s\n", tgid<<32|tids[i], prog, r, twinExtra)
	}
	ts.WriteString("dump\n")
	twin = feed(t, false, ts.String(), h.twinBin)
	return
}

func sameDump(t *testing.T, what, kernel, twin string) {
	t.Helper()
	k, w := traceDumpLines(kernel), traceDumpLines(twin)
	if strings.Join(k, "\n") != strings.Join(w, "\n") {
		t.Errorf("%s: kernel and twin dumps differ\nkernel:\n%s\ntwin:\n%s", what, strings.Join(k, "\n"), strings.Join(w, "\n"))
	}
}

// TestTracingDifferential は E053 の H2〜H4 と H5 (b): fentry / fexit (5 回の tracing の test run — tid ≠ tgid) と kprobe (poll の nfds 3・4・7) の
// kernel と双子の dump が一致、Filter が別の tgid なら kernel も双子も数えない。
func TestTracingDifferential(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	five := []string{"", "", "", "", ""}
	k, w, tg := traceDiff(t, "trace_fentry", "on_test1", five, "", true)
	sameDump(t, "fentry", k, w)
	if !strings.Contains(k, fmt.Sprintf("Calls{%d}=5\n", tg)) {
		t.Errorf("fentry: want Calls{%d}=5:\n%s", tg, k)
	}
	_, tids := traceKernel(t, k)
	for _, tid := range tids {
		if tid == tg {
			t.Errorf("a tracing test run reported tid == tgid (%d) — want another thread", tid)
		}
	}
	k, w, _ = traceDiff(t, "trace_fexit", "on_ret", five, " ret=2", true) // bpf_fentry_test1(1) は 2 を返す
	sameDump(t, "fexit", k, w)
	if !strings.Contains(k, "Rets[1]=5\n") {
		t.Errorf("fexit: want Rets[1]=5:\n%s", k)
	}
	k, w, tg = traceDiff(t, "trace_kprobe", "on_poll", []string{"a2=3", "a2=4", "a2=7"}, "", true)
	sameDump(t, "kprobe", k, w)
	if !strings.Contains(k, fmt.Sprintf("Sums{%d}=14\n", tg)) {
		t.Errorf("kprobe: want Sums{%d}=14:\n%s", tg, k)
	}
	// H5 (b): 濾しの対照 — Filter が tgid 1 なら kernel も双子も数えない
	k, w, tg = traceDiff(t, "trace_fentry", "on_test1", five, "", false)
	sameDump(t, "fentry filtered", k, w)
	if strings.Contains(k, "Calls{") {
		t.Errorf("fentry filtered: the kernel counted another tgid's runs:\n%s", k)
	}
}

// TestTracingTwinNeedsTask は E053 の H5 (c): 双子に kernel の task を挟まないと (pid_tgid 0) dump が kernel と一致しない — 2 段の意味。
func TestTracingTwinNeedsTask(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_fentry.rb"))
	k := feed(t, true, "reset\npokeself Filter 0\nself\nrun on_test1\nrun on_test1\ndump\n", h.kernelBin)
	tg, _ := traceKernel(t, k)
	w := feed(t, false, fmt.Sprintf("reset\npoke Filter 0 %d\nrun on_test1\nrun on_test1\ndump\n", tg), h.twinBin)
	if strings.Join(traceDumpLines(k), "\n") == strings.Join(traceDumpLines(w), "\n") {
		t.Errorf("the twin without the kernel's task should not match the kernel")
	}
}

// TestTracingAttachKind は E053 の H2 と H5 (a): fentry の program を kprobe / fexit として attach すると誤り、fentry として attach・test run・detach は OK。
func TestTracingAttachKind(t *testing.T) {
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "trace", "attach_kind.rb"))
	src := filepath.Join(d, "attach_kind.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "attach_kind")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe)
	t.Log(out)
	for _, w := range []string{"as fentry kind=OK", "runs tid_is_other=true calls>=3 true", "detached"} {
		if !strings.Contains(out, w+"\n") {
			t.Errorf("want %q", w)
		}
	}
	if !strings.Contains(out, "as kprobe kind=SpinelBPF::") || strings.Contains(out, "as kprobe kind=OK") || !strings.Contains(out, "as fexit kind=SpinelBPF::") || strings.Contains(out, "as fexit kind=OK") {
		t.Errorf("attaching a fentry program as kprobe / fexit must fail loudly")
	}
}
