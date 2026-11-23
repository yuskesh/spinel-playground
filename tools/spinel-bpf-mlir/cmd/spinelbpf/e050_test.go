package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// E050 の試験 (P012 — host、root): Thread の入力の双子の差動 — 双子は直列、kernel は T 個の Thread の並行。
// key ごとの値と合計の両方で比べる (合計だけだと key の取り違えが見えない — P012 のレビュー)。program は testdata/threads/tpar.rb。

type threadHarness struct{ twin, kernel string }

// buildThreadHarnesses は Thread の変種の双子と kernel の harness を作る。rewrite は kernel の .mlir の書き換え (変異の対照 — nil は無し)。
func buildThreadHarnesses(t *testing.T, rewrite func(string) (string, bool)) threadHarness {
	t.Helper()
	return buildThreadHarnessesFor(t, filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "threads", "tpar.rb"), rewrite)
}

// buildThreadHarnessesFor は source の Thread の変種の双子と kernel の harness (E059 で source を引数に)。
func buildThreadHarnessesFor(t *testing.T, src string, rewrite func(string) (string, bool)) threadHarness {
	t.Helper()
	cfg, _ := defaultConfig()
	name := strings.TrimSuffix(filepath.Base(src), ".rb")
	text, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	res, err := frontend.Analyze(frontend.Spinel{Bin: cfg.Spinel, LibDir: filepath.Join(cfg.Repo, "ruby", "lib")}, t.TempDir(), src, string(text))
	if err != nil || res.Diags.Blocking() {
		t.Fatalf("analyze: %v %v", err, res.Diags)
	}
	tw, err := frontend.TwinHarnessThreads(string(text), res)
	if err != nil {
		t.Fatal(err)
	}
	td := t.TempDir()
	os.WriteFile(filepath.Join(td, name+".rb"), []byte(tw), 0o644)
	c := exec.Command(cfg.Spinel, "-I", filepath.Join(cfg.Repo, "ruby", "lib", "native"), name+".rb", "-o", "twin")
	c.Dir, c.Env = td, append(os.Environ(), "TMPDIR="+td)
	if o, err := c.CombinedOutput(); err != nil {
		t.Fatalf("building the twin harness: %v\n%s", err, o)
	}
	kh, err := frontend.KernelHarnessThreads(string(text), res)
	if err != nil {
		t.Fatal(err)
	}
	kd, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e050-")
	if err != nil {
		t.Fatal(err)
	}
	ksrc := filepath.Join(kd, name+".rb")
	os.WriteFile(ksrc, []byte(kh), 0o644)
	if _, err := Build(cfg, ksrc); err != nil {
		t.Fatalf("building the kernel harness: %v", err)
	}
	if rewrite != nil {
		m, _ := os.ReadFile(filepath.Join(kd, name+".mlir"))
		mm, ok := rewrite(string(m))
		if !ok || mm == string(m) {
			t.Fatalf("the rewrite did not apply to %s.mlir", name)
		}
		os.WriteFile(filepath.Join(kd, name+".mlir"), []byte(mm), 0o644)
		schema, _ := os.ReadFile(filepath.Join(kd, name+".schema.json"))
		if err := runIn(kd, cfg.EbpfCompile, name+".mlir", "--schema", name+".schema.json", "-o", name+".bpf.o"); err != nil {
			t.Fatal(err)
		}
		sha, err := checkSchemaSHA(filepath.Join(kd, name+".bpf.o"), schema)
		if err != nil {
			t.Fatal(err)
		}
		_ = sha // schema は変えない — 今の embed.S (records の表・global の G の行を含む) を組み立て直すだけ (E059 — embedAsm は表を落とした)
		if err := runIn(kd, cfg.Clang, "-c", "-x", "assembler", name+"_embed.S", "-o", name+"_embed.o"); err != nil {
			t.Fatal(err)
		}
	}
	kbin := filepath.Join(kd, "kernel")
	if err := Link(cfg, ksrc, kbin); err != nil {
		t.Fatal(err)
	}
	return threadHarness{twin: filepath.Join(td, "twin"), kernel: kbin}
}

// pkt は byte 0 と byte 1 の 14 byte の packet の 16 進。
func pkt(b0, b1 int) string { return fmt.Sprintf("%02x%02x", b0, b1) + strings.Repeat("00", 12) }

// threadRows は表の行 (T・重なる / 重ならない) の手順。
func threadRows() (string, []string) {
	var script strings.Builder
	var labels []string
	for _, n := range []int{2, 4, 8} {
		for _, shape := range []string{"overlap", "disjoint"} {
			var hs []string
			for i := 0; i < n; i++ {
				if shape == "overlap" {
					hs = append(hs, pkt(3, i+1)) // 全ての Thread が key 3
				} else {
					hs = append(hs, pkt(i, 10+i)) // Thread ごとに key i & 7
				}
			}
			label := fmt.Sprintf("T%d_%s", n, shape)
			labels = append(labels, label)
			fmt.Fprintf(&script, "reset\necho %s\nprun prog 50 %s\ndump\n", label, strings.Join(hs, " "))
		}
	}
	return script.String(), labels
}

// threadCompare は 2 つの出力の dump の行 (Counts / Sums / Slots) を行の印ごとに比べ、key ごとの不一致と合計の不一致を数える。
func threadCompare(twin, kernel string) (perKey []string, totals []string) {
	parse := func(s string) map[string]map[string]string {
		out := map[string]map[string]string{}
		cur := ""
		for _, l := range strings.Split(s, "\n") {
			if strings.HasPrefix(l, "## ") {
				cur = l[3:]
				out[cur] = map[string]string{}
			} else if cur != "" && strings.Contains(l, "[") && strings.Contains(l, "]=") {
				k := l[:strings.Index(l, "=")]
				out[cur][k] = l[strings.Index(l, "=")+1:]
			}
		}
		return out
	}
	tw, kn := parse(twin), parse(kernel)
	for label, rows := range tw {
		sum := map[string][2]int64{}
		for k, v := range rows {
			if kn[label][k] != v {
				perKey = append(perKey, fmt.Sprintf("[%s] %s twin %s kernel %s", label, k, v, kn[label][k]))
			}
			m := k[:strings.Index(k, "[")]
			var a, b int64
			fmt.Sscan(v, &a)
			fmt.Sscan(kn[label][k], &b)
			s := sum[m]
			sum[m] = [2]int64{s[0] + a, s[1] + b}
		}
		for m, s := range sum {
			if s[0] != s[1] {
				totals = append(totals, fmt.Sprintf("[%s] total %s twin %d kernel %d", label, m, s[0], s[1]))
			}
		}
	}
	return perKey, totals
}

// TestThreadTwinDifferential は E050 の H1〜H3・H5: 表の全ての行で双子 (直列) と kernel (並行) が key ごとと合計で一致、ppoke も一致、並行の区間が重なった。
func TestThreadTwinDifferential(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildThreadHarnesses(t, nil)
	nm, _ := exec.Command("nm", h.kernel).Output()
	tnm, _ := exec.Command("nm", h.twin).Output()
	if !strings.Contains(string(nm), "sp_sched_init") || strings.Contains(string(tnm), "sp_sched_init") {
		t.Errorf("want a threaded kernel harness and a non-threaded twin")
	}
	script, labels := threadRows()
	script += "reset\necho ppoke\nppoke Slots 8 8\ndump\n"
	tw := feed(t, false, script, h.twin)
	kn := feed(t, true, script, h.kernel)
	perKey, totals := threadCompare(tw, kn)
	t.Logf("%d rows + ppoke: per-key mismatches %d, total mismatches %d", len(labels), len(perKey), len(totals))
	for _, m := range append(perKey, totals...) {
		t.Error(m)
	}
	for _, l := range labels {
		if !strings.Contains(tw, "## "+l+"\n") || !strings.Contains(kn, "## "+l+"\n") {
			t.Errorf("row %s missing", l)
		}
	}
	if !strings.Contains(kn, "Counts[3]=") || strings.Count(kn, "overlaps=0\n") == strings.Count(kn, "overlaps=") {
		t.Errorf("the kernel threads never overlapped (or no prun output):\n%s", firstLines(kn, 20))
	}
	t.Logf("kernel overlaps: %v", overlapLines(kn))
}

func overlapLines(s string) []string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		if strings.HasPrefix(l, "overlaps=") {
			out = append(out, l)
		}
	}
	return out
}

// TestThreadTwinKeyMix は E050 の H4 (対照): key の mask を 7 → 6 にした変異の kernel では key ごとの不一致が出て、合計は一致する
// (合計だけの比べは key の取り違えを通してしまう — 意図した理由で key ごとの比べが落とす)。
func TestThreadTwinKeyMix(t *testing.T) {
	requireUnverified(t)
	h := buildThreadHarnesses(t, replaceFirst("arith.constant 7 : i64", "arith.constant 6 : i64"))
	script, _ := threadRows()
	perKey, totals := threadCompare(feed(t, false, script, h.twin), feed(t, true, script, h.kernel))
	t.Logf("mutant: per-key mismatches %d, total mismatches %d", len(perKey), len(totals))
	if len(perKey) == 0 || len(totals) != 0 {
		t.Errorf("want per-key mismatches with equal totals, got per-key %v totals %v", perKey, totals)
	}
}
