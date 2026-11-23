package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E145 の試験 (P028 — 今の task の comm、R.output_comm): 生成物 (H1)・双子の smoke (H3)・kprobe do_sys_poll の実の attach の 2 段の差動
// (H4 — root、追補 1 の長い名前を含む 3 つの event)。負の例 (H2) は internal/frontend の testdata/neg の cm_*.rb (TestNegative)、
// 変異 (H5) は e145_mutation_test.go。

func commSrc(n string) string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", n+".rb")
}

// e145Names は H4 の comm の名前と poll の nfds (3 つ目は 20 文字 — kernel は先頭 15 byte と NUL に切り詰める — 追補 1)。
var e145Names = []struct{ name, nfds string }{{"e145a", "1"}, {"e145b", "2"}, {"e145-long-name-20c", "3"}}

// TestCommArtefacts は H1: present の中の store_record → task.comm → status の store_field → submit の順と、requirements の helper 16 (kprobe と tracepoint)。
func TestCommArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	for _, n := range []string{"trace_comm", "trace_comm_tp"} {
		d := t.TempDir()
		b, _ := os.ReadFile(commSrc(n))
		src := filepath.Join(d, n+".rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		m, _ := os.ReadFile(filepath.Join(d, n+".mlir"))
		s := string(m)
		i, j, k, l := strings.Index(s, "ebpf.ringbuf.store_record"), strings.Index(s, `ebpf.task.comm`), strings.LastIndex(s, "ebpf.ringbuf.store_field"), strings.Index(s, "ebpf.ringbuf.submit")
		if i < 0 || j < 0 || k < 0 || l < 0 || !(i < j && j < k && k < l) {
			t.Errorf("%s .mlir: want store_record → task.comm → store_field → submit (got %d %d %d %d)", n, i, j, k, l)
		}
		r := elfRequirements(t, cfg, filepath.Join(d, n+".bpf.o"))
		if !strings.Contains(string(r), "\tget_current_comm\t16\n") {
			t.Errorf("%s: requirements lack the helper get_current_comm 16:\n%s", n, r)
		}
	}
}

// commHex は名前を PR_SET_NAME の規則 (先頭 15 byte と NUL、後ろは 0) で 16 byte の hex に — 双子の smoke の期待だけに使う (H4 は prctl の読み戻し)。
func commHex(s string) string {
	b := make([]byte, 16)
	copy(b[:15], s)
	return fmt.Sprintf("%x", b)
}

// TestCommTwinSmoke は H3: 双子の `comm e145twin` と run → event 1 つ (comm は "e145twin" の 16 byte、status 0、nfds 1)。
func TestCommTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_comm")
	out := feed(t, false, "reset\npoke Filter 0 4242\ntask 18219251273881\ncomm e145twin\nrun on_poll a2=1\ndrain Events\ndump\n", tw)
	t.Log(out)
	wantLines(t, out, "Events#0.comm="+commHex("e145twin"), "Events#0.status=0", "Events#0.nfds=1", "Events drained=1", "Out[0]=1")
}

// ringLines は ring の drain の行 (Events#…・Events drained=…)。
func ringLines(out string) []string {
	var d []string
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, "Events#") || strings.HasPrefix(l, "Events drained=") {
			d = append(d, l)
		}
	}
	return d
}

// commLines は harness の `comm` の読み戻しの行 (comm=<16 byte の hex>)。
func commLines(out string) []string {
	var d []string
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, "comm=") {
			d = append(d, l)
		}
	}
	return d
}

// commDiff は H4 (と H5) の 2 段の差動: kernel は Filter に自分の tgid、名前ごとに `comm <name>` と `run on_poll a2=<nfds>` (harness の thread が
// poll(NULL, nfds, 0))、最後に drain。双子は同じ tgid・tid・名前・nfds。
func commDiff(t *testing.T, h harnessSet) (kernel, twin string) {
	t.Helper()
	var ks strings.Builder
	ks.WriteString("reset\npokeself Filter 0\nself\n")
	for _, e := range e145Names {
		ks.WriteString("comm " + e.name + "\nrun on_poll a2=" + e.nfds + "\n")
	}
	ks.WriteString("drain Events\ndump\n")
	kernel = feed(t, true, ks.String(), h.kernelBin)
	tgid, tids := traceKernel(t, kernel)
	if len(tids) != len(e145Names) {
		t.Fatalf("want %d tids, got %v:\n%s", len(e145Names), tids, kernel)
	}
	var ts strings.Builder
	ts.WriteString("reset\npoke Filter 0 " + fmt.Sprint(tgid) + "\n")
	for i, e := range e145Names {
		ts.WriteString("task " + fmt.Sprint(tgid<<32|tids[i]) + "\ncomm " + e.name + "\nrun on_poll a2=" + e.nfds + "\n")
	}
	ts.WriteString("drain Events\ndump\n")
	twin = feed(t, false, ts.String(), h.twinBin)
	return
}

// TestCommDifferential は H4 (root): kernel の ring の event がちょうど 3 つ (comm は各 `comm` の prctl の読み戻し、status 0、nfds 1 / 2 / 3)、
// 双子の comm の規則 (BPF.set_comm) の読み戻しと kernel の読み戻しが一致し、drain の行と dump が双子と byte 同じ。
func TestCommDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, commSrc("trace_comm"))
	k, w := commDiff(t, h)
	t.Log(k)
	kc, wc := commLines(k), commLines(w)
	t.Logf("kernel comm read-back %v, twin %v", kc, wc)
	if strings.Join(kc, " ") != strings.Join(wc, " ") || len(kc) != len(e145Names) {
		t.Fatalf("the twin's comm rule differs from PR_SET_NAME / PR_GET_NAME:\nkernel %v\ntwin   %v", kc, wc)
	}
	kr, wr := ringLines(k), ringLines(w)
	if strings.Join(kr, "\n") != strings.Join(wr, "\n") {
		t.Errorf("ring events differ\nkernel:\n%s\ntwin:\n%s", strings.Join(kr, "\n"), strings.Join(wr, "\n"))
	}
	var want []string
	for i, e := range e145Names {
		want = append(want, fmt.Sprintf("Events#%d.%s", i, kc[i]), fmt.Sprintf("Events#%d.status=0", i), fmt.Sprintf("Events#%d.nfds=%s", i, e.nfds)) // kc[i] は comm=<hex>

	}
	wantLines(t, k, append(want, fmt.Sprintf("Events drained=%d", len(e145Names)), fmt.Sprintf("Out[0]=%d", len(e145Names)))...)
	sameDump(t, "comm", k, w)
}
