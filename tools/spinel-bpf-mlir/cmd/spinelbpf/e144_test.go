package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E144 の試験 (P028 — fmod_ret の root の DSL): 生成物 (H1)・双子の smoke (H3)・fexit の観測の差動 (H4 — root、追補 1)・load の前の
// retsig / farg の照合と fmod の集合に無い関数 (H5 — root)。負の例 (H2) は internal/frontend の testdata/neg の fm_*.rb (TestNegative)、
// 変異 (H6) は e144_mutation_test.go。

func fmodRetSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_fmod_ret.rb")
}

// fmodOrig は kernel の元の bpf_modify_return_test の戻り値 (7.1.8 の net/bpf/test_run.c — test run が (1, &b) で b = 2 から呼び、
// *b += 1 で a + *b = 4)。双子の fmod_ret の戻り値 0 (BPF::FMOD_CALL) を fexit が見る値に写す時だけに使う (E144 追補 1)。
const fmodOrig = 4

// TestFmodRetArtefacts は H1: .mlir の kind・ctx.arg・終端 (select と ebpf.return)、ELF の requirements の trace_fmod_ret・retsig・farg。
func TestFmodRetArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(fmodRetSrc())
	src := filepath.Join(d, "trace_fmod_ret.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "trace_fmod_ret.mlir"))
	for _, w := range []string{`ebpf.program @on_guard "fmod_ret" attach "bpf_modify_return_test"`, `ebpf.ctx.arg %ctx[0] : !ebpf.ctx<"fmod_ret"> -> i32`, "arith.select", "ebpf.return", `ebpf.program @on_val "fmod_ret"`} {
		if !strings.Contains(string(m), w) {
			t.Errorf(".mlir lacks %q", w)
		}
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "trace_fmod_ret.bpf.o"))
	for _, p := range []string{"on_guard", "on_val"} {
		w := fmt.Sprintf("attach\t%s\ttrace_fmod_ret\tbpf_modify_return_test\nretsig\t%s\t2\ti32\nfarg\t%s\t0\ti32\nfarg\t%s\t1\t-\n", p, p, p, p)
		if !strings.Contains(string(r), w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
}

// TestFmodRetTwinSmoke は H3: 双子の on_guard (Cfg 0) は 0 と Out[0]=1、Cfg 1 は −1、on_val は 2。
func TestFmodRetTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_fmod_ret")
	out := feed(t, false, "reset\npoke Filter 0 4242\ntask 18219251273881\nrun on_guard a0=1\ndump\npoke Cfg 0 1\nrun on_guard a0=1\nrun on_val a0=1\n", tw) // tgid 4242 << 32 | tid 4249
	t.Log(out)
	var rets []string
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, "ret=") {
			rets = append(rets, l)
		}
	}
	if strings.Join(rets, " ") != "ret=0 ret=-1 ret=2" {
		t.Errorf("twin returns %v, want ret=0 ret=-1 ret=2", rets)
	}
	wantLines(t, out, "Out[0]=1")
}

// fmodRetDiff は H4 (と H6) の差動: kernel は fexit の on_obs を load の後に attach、fmod_ret の run ごとに attach → test run → detach を 3 回
// (on_guard の Cfg 0・Cfg 1・on_val)、run ごとに dump。双子は同じ tid の task で fmod_ret の program を走らせ、その戻り値 (0 は元の関数の 4) を
// fexit の on_obs に ret= で渡す。
func fmodRetDiff(t *testing.T, h harnessSet) (kernel, twin []string) {
	t.Helper()
	steps := []struct{ pre, prog string }{{"", "on_guard"}, {"poke Cfg 0 1\n", "on_guard"}, {"", "on_val"}}
	var ks strings.Builder
	ks.WriteString("reset\npokeself Filter 0\nself\n")
	for _, s := range steps {
		ks.WriteString(s.pre + "run " + s.prog + "\ndump\necho step\n")
	}
	k := feed(t, true, ks.String(), h.kernelBin)
	t.Log(k)
	tgid, tids := traceKernel(t, k)
	if len(tids) != len(steps) {
		t.Fatalf("want %d tids, got %v:\n%s", len(steps), tids, k)
	}
	kernel = strings.Split(k, "## step\n")
	var ts strings.Builder
	ts.WriteString("reset\npoke Filter 0 " + fmt.Sprint(tgid) + "\n")
	for i, s := range steps {
		ts.WriteString(s.pre + "task " + fmt.Sprint(tgid<<32|tids[i]) + "\nrun " + s.prog + " a0=1\n")
		// 双子の戻り値は run の行の出力から — 下の twinObs が 2 度目の feed で on_obs に渡す
	}
	tw := feed(t, false, ts.String(), h.twinBin)
	var rets []int64
	for _, l := range strings.Split(tw, "\n") {
		var v int64
		if _, err := fmt.Sscanf(l, "ret=%d", &v); err == nil {
			rets = append(rets, v)
		}
	}
	if len(rets) != len(steps) {
		t.Fatalf("want %d twin returns, got %v:\n%s", len(steps), rets, tw)
	}
	var ws strings.Builder
	ws.WriteString("reset\npoke Filter 0 " + fmt.Sprint(tgid) + "\n")
	for i, s := range steps {
		obs := rets[i]
		if obs == 0 {
			obs = fmodOrig
		}
		ws.WriteString(s.pre + "task " + fmt.Sprint(tgid<<32|tids[i]) + "\nrun " + s.prog + " a0=1\nrun on_obs ret=" + fmt.Sprint(obs) + "\ndump\necho step\n")
	}
	w := feed(t, false, ws.String(), h.twinBin)
	t.Log(w)
	twin = strings.Split(w, "## step\n")
	return
}

// TestFmodRetDifferential は H4 (root): fexit が見る戻り値が Cfg 0 → 4 (元の関数)・Cfg 1 → −1・on_val → 2、観測は run ごとに 1 つ
// (Out[2] = run の累計)、各段の dump が双子と一致。
func TestFmodRetDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, fmodRetSrc())
	k, w := fmodRetDiff(t, h)
	want := [][]string{{"Out[0]=1", "Out[2]=1", "Out[3]=4"}, {"Out[0]=2", "Out[2]=2", "Out[3]=-1"}, {"Out[0]=2", "Out[2]=3", "Out[3]=2"}}
	for i := range want {
		t.Logf("step %d kernel: %v", i, traceDumpLines(k[i]))
		sameDump(t, fmt.Sprintf("fmod_ret step %d", i), k[i], w[i])
		wantLines(t, k[i], want[i]...)
	}
}

// TestFmodRetLoadChecks は H5 (root): 引数 0 を :u64・nargs を 3 と誤った program は compile を通り load が TargetRejected (文の固定の部分
// `program on_bad:` だけを見る)。fmod の集合に無い関数 (bpf_fentry_test1) への program は load が止まる (止まる段と文は予測しない — OK でないことだけ)。
func TestFmodRetLoadChecks(t *testing.T) {
	requireUnverified(t)
	for _, n := range []string{"fm_wrong_arg", "fm_wrong_nargs"} {
		out := rawtpFixture(t, n)
		for _, w := range []string{"load kind=SpinelBPF::TargetRejected", "program on_bad:"} {
			if !strings.Contains(out, w) {
				t.Errorf("%s: the load must stop on the target's FUNC_PROTO (retsig / farg) — want %q:\n%s", n, w, out)
			}
		}
	}
	out := rawtpFixture(t, "fm_notmod")
	if strings.Contains(out, "load kind=OK") || !strings.Contains(out, "load kind=") {
		t.Errorf("fm_notmod: the load of a fmod_ret program on a function outside the kernel's fmod set must stop:\n%s", out)
	}
}
