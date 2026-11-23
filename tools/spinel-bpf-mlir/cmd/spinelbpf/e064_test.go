package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// E064 の試験: 有界の loop の表 (t_loop.rb — 84 行) の双子と kernel の差動と、kernel の .mlir の書き換えの変異 5 つ (P015 §3)。

func loopTableSrc() string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "loop", "t_loop.rb")
}

var loopKs = []int64{0, 1, 2, 8, 15, -1, 2147483647}
var loopBpos = []int64{0, 3, 11, 13}

// loopPackets は TLV 3 個と終わり・(5, 0) を 7 個 (6 で打ち切り)・15 byte (最初の窓の外)。
var loopPackets = []string{
	tlvPacket([]int{1, 0, 2, 1, 9, 3, 0, 0}, 64),
	tlvPacket([]int{5, 0, 5, 0, 5, 0, 5, 0, 5, 0, 5, 0, 5, 0}, 64),
	tlvPacket(nil, 15),
}

type loopRow struct {
	k, bpos int64
	pkt     int
}

// loopScript は 84 行の手順 (行ごとに `echo r<i>` の印 — hash の dump の行の数は双子と変異の kernel で違いうるので印で分ける)。
func loopScript() (string, []loopRow) {
	var b strings.Builder
	var rows []loopRow
	for _, k := range loopKs {
		for _, bp := range loopBpos {
			for pi, p := range loopPackets {
				fmt.Fprintf(&b, "echo r%d\nreset\npoke In 0 %d\npoke In 1 %d\nrun prog %s\ndump\n", len(rows), k, bp, p)
				rows = append(rows, loopRow{k, bp, pi})
			}
		}
	}
	return b.String(), rows
}

// loopBlocks は出力を行の印で分け、行ごとに key (`X=` の前、無ければ行) → 値の map にする。
func loopBlocks(t *testing.T, out string, n int) []map[string]string {
	t.Helper()
	var blocks []map[string]string
	for _, l := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if strings.HasPrefix(l, "## r") {
			blocks = append(blocks, map[string]string{})
			continue
		}
		if len(blocks) == 0 {
			t.Fatalf("output before the first row marker: %q", l)
		}
		k, v := l, ""
		if i := strings.Index(l, "="); i > 0 {
			k, v = l[:i], l[i+1:]
		}
		blocks[len(blocks)-1][k] = v
	}
	if len(blocks) != n {
		t.Fatalf("%d row blocks, want %d:\n%s", len(blocks), n, out)
	}
	return blocks
}

// slotOf は key の分類 — Out は slot ごと、他の map は map の名前 (Cnt・H)。
func slotOf(key string) string {
	if strings.HasPrefix(key, "Out[") {
		return key
	}
	if i := strings.IndexAny(key, "[{"); i > 0 {
		return key[:i]
	}
	return key
}

// loopDiff は行ごとの食い違う slot の集合。
func loopDiff(t *testing.T, twin, kernel string, n int) map[int]map[string]bool {
	tw, kn := loopBlocks(t, twin, n), loopBlocks(t, kernel, n)
	out := map[int]map[string]bool{}
	for i := 0; i < n; i++ {
		keys := map[string]bool{}
		for k := range tw[i] {
			keys[k] = true
		}
		for k := range kn[i] {
			keys[k] = true
		}
		for k := range keys {
			a, oka := tw[i][k]
			b, okb := kn[i][k]
			if oka != okb || a != b {
				if out[i] == nil {
					out[i] = map[string]bool{}
				}
				out[i][slotOf(k)] = true
			}
		}
	}
	return out
}

// TestLoopTable は E064 の H1 (root): 84 行で双子と kernel の dump が一致。
func TestLoopTable(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildHarnesses(t, loopTableSrc())
	script, rows := loopScript()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	d := loopDiff(t, tw, kn, len(rows))
	for i, s := range d {
		t.Errorf("row %d %+v: twin and kernel differ in %v", i, rows[i], keysOf(s))
	}
	t.Logf("%d rows, %d differing", len(rows), len(d))
}

func keysOf(m map[string]bool) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// mutatedLoopKernel は表の program の kernel の harness を .mlir の書き換えで build し直す (今の embed.S を組み立て直す — records の表を落とさない、E059)。
func mutatedLoopKernel(t *testing.T, h harnessSet, rewrite func(string) (string, bool)) string {
	t.Helper()
	cfg, _ := defaultConfig()
	d := filepath.Dir(h.kernelBin)
	name := "t_loop"
	m, err := os.ReadFile(filepath.Join(d, name+".mlir"))
	if err != nil {
		t.Fatal(err)
	}
	mm, ok := rewrite(string(m))
	if !ok || mm == string(m) {
		t.Fatalf("the rewrite did not apply to %s.mlir", name)
	}
	md := t.TempDir()
	for _, f := range []string{name + ".rb", name + ".schema.json", name + ".maps.json", name + "_embed.S"} {
		b, err := os.ReadFile(filepath.Join(d, f))
		if err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(md, f), b, 0o644)
	}
	os.WriteFile(filepath.Join(md, name+".mlir"), []byte(mm), 0o644)
	if err := runIn(md, cfg.EbpfCompile, name+".mlir", "--schema", name+".schema.json", "-o", name+".bpf.o"); err != nil {
		t.Fatal(err)
	}
	if err := runIn(md, cfg.Clang, "-c", "-x", "assembler", name+"_embed.S", "-o", name+"_embed.o"); err != nil {
		t.Fatal(err)
	}
	mut := filepath.Join(md, "kernel_mut")
	if err := Link(cfg, filepath.Join(md, name+".rb"), mut); err != nil {
		t.Fatal(err)
	}
	return mut
}

// boundOf は `ebpf.loop N unroll bound(%x)` の %x。
func boundOf(s string, n int) string {
	m := regexp.MustCompile(fmt.Sprintf(`ebpf\.loop %d unroll bound\((%%v\d+)\)`, n)).FindStringSubmatch(s)
	if m == nil {
		return ""
	}
	return m[1]
}

// TestLoopMutations は E064 の H2〜H6 (root): 変異ごとに食い違う行と slot が予測どおり (意図した理由で落ちたか)。
func TestLoopMutations(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildHarnesses(t, loopTableSrc())
	script, rows := loopScript()
	tw := feed(t, false, script, h.twinBin)
	kk := func(r loopRow) int64 { return (r.k & 15) - 1 }
	for _, c := range []struct {
		name    string
		rewrite func(string) (string, bool)
		slots   []string           // 食い違ってよい slot (全て)
		want    func(loopRow) bool // 食い違う行
	}{
		{"M1 break→continue", replaceFirst("ebpf.break ", "ebpf.continue "), []string{"Out[0]"}, func(r loopRow) bool { return r.bpos != 13 && r.bpos != 11 }}, // H2 の予測 (bpos ≠ 13) は外れ — bpos 11 は最後の iteration (i = 11) の break で、continue でも同じ (加算を飛ばして loop が終わる)
		{"M2 N 12→11", replaceFirst("ebpf.loop 12 unroll", "ebpf.loop 11 unroll"), []string{"Out[0]"}, func(r loopRow) bool { return r.bpos == 13 }},
		{"M3 no bound", func(s string) (string, bool) {
			b := boundOf(s, 14)
			if b == "" {
				return s, false
			}
			return strings.Replace(s, "ebpf.loop 14 unroll bound("+b+")", "ebpf.loop 14 unroll", 1), true
		}, []string{"Out[2]", "Cnt", "H"}, func(r loopRow) bool { return kk(r) != 14 }},
		{"M4 no negative clamp", func(s string) (string, bool) {
			b := boundOf(s, 14)
			if b == "" {
				return s, false
			}
			// b = arith.trunci %r — %r は clamp の ebpf.if の結果、その else の yield が clamp の前の値
			tr := regexp.MustCompile(regexp.QuoteMeta(b) + ` = arith\.trunci (%v\d+) : i64 to i32`).FindStringSubmatch(s)
			if tr == nil {
				return s, false
			}
			cl := regexp.MustCompile(regexp.QuoteMeta(tr[1]) + ` = ebpf\.if %v\d+ -> i64 \{\n[^\n]*\n[^\n]*\} else \{\n\s*ebpf\.if\.yield (%v\d+) : i64`).FindStringSubmatch(s)
			if cl == nil {
				return s, false
			}
			return strings.Replace(s, b+" = arith.trunci "+tr[1]+" :", b+" = arith.trunci "+cl[1]+" :", 1), true
		}, []string{"Out[2]", "Cnt", "H"}, func(r loopRow) bool { return kk(r) == -1 }},
		{"M5 result = init", func(s string) (string, bool) {
			m := regexp.MustCompile(`(%v\d+) = ebpf\.loop 20 unroll \((%v\d+)\)`).FindStringSubmatchIndex(s)
			if m == nil {
				return s, false
			}
			res, init := s[m[2]:m[3]], s[m[4]:m[5]]
			head, tail := s[:m[1]], s[m[1]:]
			return head + regexp.MustCompile(regexp.QuoteMeta(res)+`\b`).ReplaceAllString(tail, init), true
		}, []string{"Out[7]"}, func(r loopRow) bool { return true }},
	} {
		t.Run(c.name, func(t *testing.T) {
			kn := feed(t, true, script, mutatedLoopKernel(t, h, c.rewrite))
			d := loopDiff(t, tw, kn, len(rows))
			allowed := map[string]bool{}
			for _, s := range c.slots {
				allowed[s] = true
			}
			bad, got := 0, 0
			for i, r := range rows {
				s, differs := d[i]
				if differs {
					got++
				}
				if differs != c.want(r) {
					bad++
					t.Errorf("row %d %+v: differs=%v, want %v (%v)", i, r, differs, c.want(r), keysOf(s))
				}
				for k := range s {
					if !allowed[k] {
						t.Errorf("row %d %+v: unexpected slot %s differs", i, r, k)
					}
				}
			}
			t.Logf("%s: %d rows differ (prediction misses %d)", c.name, got, bad)
		})
	}
}
