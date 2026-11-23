package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E155 の試験 (P029 §2 段 2b — 検査済みの kernel pointer の address `q.addr`、bpf-mlir E554): 生成物 (H1)・双子の smoke・自分の file の O_DIRECT の読みの
// fentry blk_mq_start_request / blk_mq_end_request の観測 (H3 — root、Filter の窓、kernel の側の条件 — 追補 1・2)。負の例 (H2 — 追補 3) は
// internal/frontend の testdata/neg の kad_*.rb (TestNegative)、変異 kaddr-zero は e155_mutation_test.go、biosnoop の selftest は TestBccSelftestBiosnoop。

func kaddrSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_kaddr_request.rb")
}

// TestKaddrArtefacts は H1: .mlir の ebpf.kptr.addr、requirements の形式 17 と request の kfield の行 (kptr.addr の新しい行は無い — E554)。
func TestKaddrArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(kaddrSrc())
	src := filepath.Join(d, "trace_kaddr_request.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "trace_kaddr_request.mlir"))
	if n := strings.Count(string(m), `= ebpf.kptr.addr %v1 : !ebpf.kptr<"request"> -> i64`); n != 3 {
		t.Errorf(".mlir has %d ebpf.kptr.addr, want 3", n)
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "trace_kaddr_request.bpf.o"))
	for _, w := range []string{"kfield\ton_start\trequest\t__sector\tu64\n", "kfield\ton_start\trequest\t__data_len\tu32\n"} {
		if !strings.Contains(string(r), w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
	if strings.Contains(string(r), "kptr") {
		t.Errorf("requirements mention kptr — kptr.addr adds no requirements row (E554):\n%s", r)
	}
}

// TestKaddrTwinSmoke は双子の smoke: harness の a0@addr が q.addr に、a0.__sector / a0.__data_len が flat の読みに届く。
func TestKaddrTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_kaddr_request")
	out := feed(t, false, "reset\npoke Filter 0 4242\ntask 18219251273881\nrun on_start a0@addr=-123456789 a0.__sector=777 a0.__data_len=4096\nrun on_end a0@addr=-123456789\nrun on_end a0@addr=5\ndump\n", tw)
	t.Log(out)
	wantLines(t, out, "Last[0].addr=-123456789", "Last[0].sector=777", "Last[0].len=4096", "Out[0]=1", "Out[1]=1", "Out[2]=1")
}

// kaddrObserve は H3 の 1 回 (root): kernel は Filter に自分の tgid を書いた直後に dir の自分の file の O_DIRECT の 4 KiB の読みを 3 回、直後に Filter を 0 に。
func kaddrObserve(t *testing.T, h harnessSet, dir string) (out string, want int64) {
	t.Helper()
	out = feed(t, true, "reset\nself\npokeself Filter 0\nodirect "+dir+" 3\npoke Filter 0 0\ndump\n", h.kernelBin)
	var reads int64 = -1
	for _, l := range strings.Split(out, "\n") {
		fmt.Sscanf(l, "reads=%d", &reads)
		fmt.Sscanf(l, "want_sector=%d", &want)
	}
	if reads != 3 || want <= 0 {
		t.Fatalf("want reads=3 and a positive FIEMAP sector in the kernel harness output:\n%s", out)
	}
	return
}

// dumpInt は dump の `<name>=<v>` の値 (無ければ ok=false)。
func dumpInt(out, name string) (int64, bool) {
	for _, l := range strings.Split(out, "\n") {
		var v int64
		if _, err := fmt.Sscanf(l, name+"=%d", &v); err == nil {
			return v, true
		}
	}
	return 0, false
}

// TestKaddrDifferential は H3 (root — 追補 1・2 の kernel の側の条件): 自分の start が 1 つ以上 (Out[0] ≥ 1)、Last の len 4096・addr ≠ 0・addr の上位 16 bit が
// 0xffff・sector が FIEMAP + partition の start の期待値、join (Out[1] — 観測された end の key ⊆ start の key) は host では 0 を予測 (batch の完了 — 0 でなければ
// 予測の外として名指して記録、止めない)。dir は repo の build/tmp (block device の上 — sudo は TMPDIR を落とす、E148)。
func TestKaddrDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, kaddrSrc())
	dir := filepath.Join(repoRoot(), "build", "tmp")
	k, want := kaddrObserve(t, h, dir)
	t.Log(k)
	starts, _ := dumpInt(k, "Out[0]")
	addr, _ := dumpInt(k, "Last[0].addr")
	sector, _ := dumpInt(k, "Last[0].sector")
	ln, _ := dumpInt(k, "Last[0].len")
	joins, _ := dumpInt(k, "Out[1]")
	t.Logf("starts=%d addr=%#x sector=%d want_sector=%d len=%d joins=%d", starts, uint64(addr), sector, want, ln, joins)
	if starts < 1 {
		t.Errorf("no start of this process's request was observed (Out[0]=%d)", starts)
	}
	if ln != 4096 {
		t.Errorf("Last[0].len = %d, want 4096", ln)
	}
	if addr == 0 || uint64(addr)>>48 != 0xffff {
		t.Errorf("Last[0].addr = %#x — want a non-zero kernel address with the top 16 bits 0xffff", uint64(addr))
	}
	if sector != want {
		t.Errorf("Last[0].sector = %d, the FIEMAP extent and the partition start give %d", sector, want)
	}
	if joins != 0 {
		t.Logf("PREDICTION MISS (named, not a failure — E155 追補 2): %d ends joined a start key on this host (predicted 0 — nvme0n1 completes in batches)", joins)
	}
}

// TestBccSelftestBiosnoop は E155 の H4 (biosnoop — selftest の file の dir を --dir で、biolatency と同じ — E148 追補 2)。
func TestBccSelftestBiosnoop(t *testing.T) {
	requireUnverified(t) // E046
	cfg, _ := defaultConfig()
	d := t.TempDir()
	src := bccSource(t, d, "bcc/biosnoop")
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "biosnoop")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe, "--selftest", "--dir", filepath.Join(repoRoot(), "build", "tmp"))
	t.Log(out)
	if !strings.Contains(out, "selftest ok") {
		t.Errorf("--selftest: want %q in the output", "selftest ok")
	}
}
