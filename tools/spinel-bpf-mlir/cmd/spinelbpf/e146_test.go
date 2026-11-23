package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E146 の試験 (P028 — kprobe の :ptr の引数の値 — bpf-mlir E327): 生成物 (H1)・双子の smoke (H3)・do_sys_openat2 の filename の address の 2 段の差動
// (H4 — root、追補 1 の窓)・load の前の kprobearg の照合 (H5 — root)。負の例 (H2) は internal/frontend の testdata/neg の kr_*.rb (TestNegative —
// kr_arg_ptr は外した)、変異 (H6) は e146_mutation_test.go。

func ptrValSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_kprobe_ptrval.rb")
}

// TestPtrValArtefacts は H1: .mlir の `ebpf.kprobe.arg %ctx 2 … -> i64`、requirements の kprobearg の ptr の 2 行。
func TestPtrValArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(ptrValSrc())
	src := filepath.Join(d, "trace_kprobe_ptrval.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "trace_kprobe_ptrval.mlir"))
	if !strings.Contains(string(m), `ebpf.kprobe.arg %ctx 2 : !ebpf.ctx<"kprobe"> -> i64`) {
		t.Errorf(".mlir lacks the raw i64 read of the pointer argument:\n%s", m)
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "trace_kprobe_ptrval.bpf.o"))
	if !strings.Contains(string(r), "kprobearg\ton_open\t2\tptr\nkprobearg\ton_open\t3\tptr\n") {
		t.Errorf("requirements lack the kprobearg ptr rows:\n%s", r)
	}
}

// TestPtrValTwinSmoke は H3: 双子に a2 (user の address らしい値) を 2 回 → Out[0] はその値・Out[1]=2・Seen{値}=2。
func TestPtrValTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_kprobe_ptrval")
	run := "run on_open a2=140737488350000 a3=5\n"
	out := feed(t, false, "reset\npoke Filter 0 4242\ntask 18219251273881\n"+run+run+"dump\n", tw)
	t.Log(out)
	wantLines(t, out, "Out[0]=140737488350000", "Out[1]=2", "Seen{140737488350000}=2")
}

// ptrValDiff は H4 (と H6) の 2 段の差動 (追補 1): kernel は Filter に自分の tgid を書いた直後に openat2 を 2 回、直後に Filter を 0 に (窓を閉じる)、
// 双子は同じ tgid・tid と kernel の出した fname を a2= に 2 回。
func ptrValDiff(t *testing.T, h harnessSet) (kernel, twin string, fname int64) {
	t.Helper()
	kernel = feed(t, true, "reset\nself\npokeself Filter 0\nopenat2 0 0 2\npoke Filter 0 0\ndump\n", h.kernelBin)
	var tgid, tid int64
	for _, l := range strings.Split(kernel, "\n") {
		fmt.Sscanf(l, "tgid=%d", &tgid)
		fmt.Sscanf(l, "tid=%d", &tid)
		fmt.Sscanf(l, "fname=%d", &fname)
	}
	if tgid == 0 || tid == 0 || fname == 0 {
		t.Fatalf("no tgid / tid / fname in the kernel harness output:\n%s", kernel)
	}
	run := fmt.Sprintf("run on_open a2=%d a3=0\n", fname)
	twin = feed(t, false, fmt.Sprintf("reset\npoke Filter 0 %d\ntask %d\n%s%spoke Filter 0 0\ndump\n", tgid, tgid<<32|tid, run, run), h.twinBin)
	return
}

// TestPtrValDifferential は H4 (root): kernel の Out[0] が harness の fname と**ちょうど**同じ、Out[1]=2、Seen の key は fname の 1 つだけで 2、dump が双子と byte 同じ。
func TestPtrValDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, ptrValSrc())
	k, w, fname := ptrValDiff(t, h)
	t.Log(k)
	var seen []string
	for _, l := range traceDumpLines(k) {
		if strings.HasPrefix(l, "Seen{") {
			seen = append(seen, l)
		}
	}
	t.Logf("fname=%d Seen=%v", fname, seen)
	wantLines(t, k, fmt.Sprintf("Out[0]=%d", fname), "Out[1]=2", fmt.Sprintf("Seen{%d}=2", fname))
	if len(seen) != 1 {
		t.Errorf("Seen has keys other than fname (another open inside the window?): %v", seen)
	}
	sameDump(t, "kprobe ptr value", k, w)
}

// TestPtrValLoadCheck は H5 (root): int dfd を :ptr と宣言した program は compile を通り、load が TargetRejected (文の固定の部分 `program on_bad:` だけ)。
func TestPtrValLoadCheck(t *testing.T) {
	requireUnverified(t)
	out := rawtpFixture(t, "kp_int_as_ptr")
	for _, w := range []string{"load kind=SpinelBPF::TargetRejected", "program on_bad:"} {
		if !strings.Contains(out, w) {
			t.Errorf("kp_int_as_ptr: the load must stop on kprobearg (the target's argument is not a pointer) — want %q:\n%s", w, out)
		}
	}
}
