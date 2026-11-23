package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E143 の試験 (P028 — ksyscall の :user_str の引数、bpf-mlir E547): 生成物 (H1)・双子の smoke (H3)・openat の 4 つの path の 2 段の差動
// (H4 — root、E142 と同じ窓)・load の前の sysarg strptr の照合 (H5 — root)。負の例 (H2) は internal/frontend の testdata/neg の kss_*.rb
// (TestNegative)、変異 (H6) は e143_mutation_test.go。

func ksysStrSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_ksys_user_str.rb")
}

// TestKsysStrArtefacts は H1: .mlir の ksyscall.arg -> !ebpf.user_str と read_str、schema の params の {kind: user_str}、requirements の形式 16 と sysarg strptr。
func TestKsysStrArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(ksysStrSrc())
	src := filepath.Join(d, "trace_ksys_user_str.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "trace_ksys_user_str.mlir"))
	for _, w := range []string{`ebpf.ksyscall.arg %ctx 2 : !ebpf.ctx<"ksyscall"> -> !ebpf.user_str`, "ebpf.user.read_str"} {
		if !strings.Contains(string(m), w) {
			t.Errorf(".mlir lacks %q", w)
		}
	}
	s, _ := os.ReadFile(filepath.Join(d, "trace_ksys_user_str.schema.json"))
	if !strings.Contains(string(s), `"kind": "user_str"`) {
		t.Errorf("schema lacks the user_str parameter type:\n%s", s)
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "trace_ksys_user_str.bpf.o"))
	for _, w := range []string{"ebpf-requirements 16\n", "sysarg\ton_open\t2\tstrptr\n"} {
		if !strings.Contains(string(r), w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
}

// TestKsysStrTwinSmoke は H3: 双子の短い path は name と status 16、NULL は 0 の name と −14。
func TestKsysStrTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_ksys_user_str")
	out := feed(t, false, "reset\npoke Filter 0 4242\ntask 18219251273881\nrun on_open a2=/tmp/e143-short a3=0\nrun on_open a2=@null a3=0\ndrain Events\n", tw)
	t.Log(out)
	wantLines(t, out, "Events#0.name="+strHex("/tmp/e143-short", 32), "Events#0.status=16", "Events#0.flags=0",
		"Events#1.name="+strHex("", 32), "Events#1.status=-14", "Events drained=2")
}

// ksysStrDiff は H4 (と H6) の 2 段の差動 (E142 と同じ窓と path): kernel は Filter に自分の tgid を書いた直後に 4 つの openat、直後に Filter を 0 に、
// 双子は同じ tgid・tid と path (flags は harness の O_RDONLY の 0)。
func ksysStrDiff(t *testing.T, h harnessSet) (kernel, twin string) {
	t.Helper()
	var ks strings.Builder
	ks.WriteString("reset\nself\npokeself Filter 0\n")
	for _, p := range e142Paths {
		ks.WriteString("openat " + p + " 1\n")
	}
	ks.WriteString("poke Filter 0 0\ndrain Events\ndump\n")
	kernel = feed(t, true, ks.String(), h.kernelBin)
	var tgid int64
	var tids []int64
	for _, l := range strings.Split(kernel, "\n") {
		fmt.Sscanf(l, "tgid=%d", &tgid)
		var v int64
		if _, err := fmt.Sscanf(l, "tid=%d", &v); err == nil {
			tids = append(tids, v)
		}
	}
	if tgid == 0 || len(tids) != len(e142Paths) {
		t.Fatalf("want tgid and %d tids in the kernel harness output:\n%s", len(e142Paths), kernel)
	}
	var ts strings.Builder
	ts.WriteString(fmt.Sprintf("reset\npoke Filter 0 %d\n", tgid))
	for i, p := range e142Paths {
		ts.WriteString(fmt.Sprintf("task %d\nrun on_open a2=%s a3=0\n", tgid<<32|tids[i], p))
	}
	ts.WriteString("poke Filter 0 0\ndrain Events\ndump\n")
	twin = feed(t, false, ts.String(), h.twinBin)
	return
}

// TestKsysStrDifferential は H4 (root): kernel の event がちょうど 4 つ — status 18・32・1 (空 — 7.1.8)・−14 (NULL)、flags 0、
// drain の行と dump が双子と byte 同じ。
func TestKsysStrDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, ksysStrSrc())
	k, w := ksysStrDiff(t, h)
	t.Log(k)
	kr, wr := ringLines(k), ringLines(w)
	if strings.Join(kr, "\n") != strings.Join(wr, "\n") {
		t.Errorf("ring events differ\nkernel:\n%s\ntwin:\n%s", strings.Join(kr, "\n"), strings.Join(wr, "\n"))
	}
	wantLines(t, k, "Events#0.status=18", "Events#1.status=32", "Events#2.status=1", "Events#3.status=-14",
		"Events#0.flags=0", "Events#3.flags=0", "Events drained=4", "Out[0]=4")
	sameDump(t, "ksyscall user_str", k, w)
}

// TestKsysStrLoadCheck は H5 (root): int の flags を :user_str と宣言した program は compile を通り、load が TargetRejected で文に program の
// 名前 on_bad を含む (区切りの記号は予測しない — E142 の H5 の教訓)。
func TestKsysStrLoadCheck(t *testing.T) {
	requireUnverified(t)
	out := rawtpFixture(t, "ks_str_on_int")
	for _, w := range []string{"load kind=SpinelBPF::TargetRejected", "on_bad"} {
		if !strings.Contains(out, w) {
			t.Errorf("ks_str_on_int: the load must stop on sysarg strptr (the argument is not a char *) — want %q:\n%s", w, out)
		}
	}
}
