package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E119 の試験 (P026 — kernel の struct の配列の member を ring の event へ): 生成物 (H1)・双子の smoke (H3)・fork の実の attach の 2 段の差動 (H4 — root)。
// 負の例 (H2) は internal/frontend の testdata/neg の kcr_*.rb (TestNegative)。

func kcopyRingSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_kcopy_ring.rb")
}

// e119Comm は harness の `comm e119ring` の後の PR_GET_NAME の 16 byte ("e119ring" と NUL 8 byte)。
const e119Comm = "6531313972696e670000000000000000"

// TestKcopyRingArtefacts は H1: present の中の store_record → kfield.copy (写し先は予約) → submit の順、ELF の requirements の版 5 と kfield comm。
func TestKcopyRingArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(kcopyRingSrc())
	src := filepath.Join(d, "trace_kcopy_ring.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "trace_kcopy_ring.mlir"))
	s := string(m)
	i, j, k := strings.Index(s, "ebpf.ringbuf.store_record"), strings.Index(s, `ebpf.kfield.copy`), strings.Index(s, "ebpf.ringbuf.submit")
	if i < 0 || j < 0 || k < 0 || !(i < j && j < k) {
		t.Errorf(".mlir: want store_record → kfield.copy → submit (got %d %d %d)", i, j, k)
	}
	if !strings.Contains(s, `"comm" : !ebpf.kptr<"task_struct">, !ebpf.reservation<!ebpf.record<"Ev", 20>>`) {
		t.Errorf(".mlir: the copy's destination is not the reservation:\n%s", s)
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "trace_kcopy_ring.bpf.o"))
	for _, w := range []string{"ebpf-requirements 5\n", "kfield\ton_fork\ttask_struct\tcomm\t[16]u8\n", "attach\ton_fork\ttrace_raw_tp\tsched_process_fork\n"} {
		if !strings.Contains(string(r), w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
}

// kcopyRingTwin は双子の run の列 (Cfg は tgid、子ごとに a1.pid / a1.tgid とその comm)。
func kcopyRingTwin(t *testing.T, tw string, tgid string, kids []string) string {
	t.Helper()
	var in strings.Builder
	in.WriteString("reset\npoke Cfg 0 " + tgid + "\n")
	for _, c := range kids {
		in.WriteString("run on_fork a0.tgid=" + tgid + " a1.pid=" + c + " a1.tgid=" + c + " a1.comm=" + e119Comm + "\n")
	}
	in.WriteString("drain Events\n")
	return feed(t, false, in.String(), tw)
}

// kcopyRingWant は kids の event の行 (comm は e119Comm、pid は子)。
func kcopyRingWant(kids []string) []string {
	var w []string
	for i, c := range kids {
		w = append(w, fmt.Sprintf("Events#%d.comm=%s", i, e119Comm), fmt.Sprintf("Events#%d.pid=%s", i, c))
	}
	return append(w, fmt.Sprintf("Events drained=%d", len(kids)))
}

// TestKcopyRingTwinSmoke は H3: 双子の 2 つの event (comm は "e119ring" の 16 byte、pid 5001 / 5002)。
func TestKcopyRingTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_kcopy_ring")
	kids := []string{"5001", "5002"}
	wantLines(t, kcopyRingTwin(t, tw, "4242", kids), kcopyRingWant(kids)...)
}

// kcopyRingDiff は H4 (と H5) の 2 段の差動: kernel は Cfg に自分の tgid、`comm e119ring` と fork × 2、双子は同じ tgid・子の pid・comm。
func kcopyRingDiff(t *testing.T, h harnessSet) (kernel, twin string, kids []string) {
	t.Helper()
	kernel = feed(t, true, "reset\nself\npokeself Cfg 0\ncomm e119ring\nfork\nfork\ndrain Events\n", h.kernelBin)
	var tgid, comm string
	for _, l := range strings.Split(kernel, "\n") {
		l = strings.TrimSpace(l)
		switch {
		case strings.HasPrefix(l, "tgid="):
			tgid = strings.TrimPrefix(l, "tgid=")
		case strings.HasPrefix(l, "comm="):
			comm = strings.TrimPrefix(l, "comm=")
		case strings.HasPrefix(l, "child="):
			kids = append(kids, strings.TrimPrefix(l, "child="))
		}
	}
	if tgid == "" || comm != e119Comm || len(kids) != 2 {
		t.Fatalf("kernel harness output (want comm=%s and 2 children):\n%s", e119Comm, kernel)
	}
	twin = kcopyRingTwin(t, h.twinBin, tgid, kids)
	return
}

// TestKcopyRingForkDifferential は H4 (root): kernel の ring の event がちょうど 2 つ — comm は harness の 16 byte、pid は子 — で双子と一致。
func TestKcopyRingForkDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, kcopyRingSrc())
	k, w, kids := kcopyRingDiff(t, h)
	t.Log(k)
	if strings.Join(kstrEvents(k), "\n") != strings.Join(kstrEvents(w), "\n") {
		t.Errorf("kernel events differ from the twin:\nkernel:\n%s\ntwin:\n%s", strings.Join(kstrEvents(k), "\n"), strings.Join(kstrEvents(w), "\n"))
	}
	wantLines(t, k, kcopyRingWant(kids)...)
}
