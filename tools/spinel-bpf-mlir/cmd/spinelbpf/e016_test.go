package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// E016 の試験: packet の表と変異の対照 (host)・load の時の CAP_PERFMON の hint (P004 §5・レビューの (c) P3)。

// kernelHarnessOf は source の kernel の harness の実行 file。
func kernelHarnessOf(t *testing.T, src string) string {
	t.Helper()
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	text, _ := os.ReadFile(src)
	sp := frontend.Spinel{Bin: cfg.Spinel, LibDir: filepath.Join(cfg.Repo, "ruby", "lib")}
	res, err := frontend.Analyze(sp, t.TempDir(), src, string(text))
	if err != nil || res.Diags.Blocking() {
		t.Fatalf("analyze %s: %v %v", src, err, res.Diags)
	}
	return buildKernelHarness(t, cfg, filepath.Base(src), string(text), res)
}

// nonroot は bin を uid 1000・caps だけで走らせる (bpf-mlir docs/nonroot.md の setpriv の形 — root が権限を落とす)。
func nonroot(t *testing.T, caps, stdin, bin string, args ...string) (string, error) { // args: 実行 file の引数 (E079)
	t.Helper()
	if os.Getenv("SPINELBPF_NO_ROOT") == "1" {
		t.Skip("SPINELBPF_NO_ROOT=1")
	}
	c := "-all," + caps
	cmd := sudoCmd(t, append([]string{"setpriv", "--reuid=1000", "--regid=1000", "--clear-groups",
		"--inh-caps=" + c, "--ambient-caps=" + c, "--bounding-set=" + c, bin}, args...)...)
	cmd.Stdin = strings.NewReader(stdin)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// TestPacketNonrootHint は E016 の H3 (host): CAP_BPF + CAP_NET_ADMIN の uid 1000 で、可変の offset の窓の例は load が拒否され文に CAP_PERFMON の hint、
// 定数の offset だけの例は通る。CAP_PERFMON を足すと可変の offset の例も通る。
func TestPacketNonrootHint(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	pos := filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos")
	for _, c := range []struct {
		name, caps string
		refused    bool
	}{
		{"pkt_ether", "+bpf,+net_admin", false},
		{"pkt_bounds", "+bpf,+net_admin", false},
		{"pkt_nested", "+bpf,+net_admin", true},
		{"pkt_off_masked", "+bpf,+net_admin", true},
		{"pkt_nested", "+bpf,+net_admin,+perfmon", false},
		{"pkt_off_masked", "+bpf,+net_admin,+perfmon", false},
	} {
		bin := kernelHarnessOf(t, filepath.Join(pos, c.name+".rb"))
		out, err := nonroot(t, c.caps, "reset\ndump\n", bin)
		hinted := strings.Contains(out, "needs CAP_PERFMON")
		t.Logf("%s (%s): err=%v hint=%v\n%s", c.name, c.caps, err, hinted, firstLines(out, 4))
		switch {
		case c.refused && (err == nil || !hinted || !strings.Contains(out, "prohibited for !root")):
			t.Errorf("%s (%s): want a refused load with the CAP_PERFMON hint", c.name, c.caps)
		case !c.refused && (err != nil || strings.Contains(out, "err=")):
			t.Errorf("%s (%s): want the load to pass", c.name, c.caps)
		}
	}
}

func firstLines(s string, n int) string {
	ls := strings.Split(s, "\n")
	if len(ls) > n {
		ls = ls[:n]
	}
	return strings.Join(ls, "\n")
}

// tPktRows は t_pkt.rb の表 (期待の値を持たない): 長さ × 種 × byte 1 (可変の offset の元) × Seen の値。
func tPktRows(s int) []pktRow {
	var rows []pktRow
	for _, n := range []int{0, 1, 13, 14, 15, 17, 18, 19, 20, 33, 34, 35, 45, 46, 60, 77, 80, 81, 100, 1500} {
		for _, b1 := range []int{0, 17, 40, 63, 255} {
			rows = append(rows, pktRow{[]string{"poke Seen 0 " + itoa(s*37+n)}, frame(n, b1*3+s*101, map[int]int{1: b1})})
		}
	}
	return rows
}

func itoa(n int) string { return strconv.Itoa(n) }

// pktResult は 1 つの表の比較の結果。
type pktResult struct {
	rows, both, short int
	bad               []string // 不一致の行 (twin と kernel、twin と CRuby)
	slots             map[string]int
}

// pktScript は行の命令の列。
func pktScript(prog string, rows []pktRow) string {
	var b strings.Builder
	for _, r := range rows {
		b.WriteString("reset\n")
		for _, p := range r.pokes {
			b.WriteString(p + "\n")
		}
		b.WriteString("run " + prog + " " + hexOf(r.frame) + "\ndump\n")
	}
	return b.String()
}

// comparePkt は twin・kernel・CRuby の出力を行ごとに比べる (E015 と同じ規則 — 14 byte 以上は 3 者、未満は双子 2 者と kernel の誤りの行)。
// 不一致の dump の行の slot の名前を数える (変異が意図した slot で落ちたかを見る)。
func comparePkt(rows []pktRow, dl int, twin, kernel, cruby string) pktResult {
	tw, kn, rb := strings.Split(twin, "\n"), strings.Split(kernel, "\n"), strings.Split(cruby, "\n")
	r := pktResult{rows: len(rows), slots: map[string]int{}}
	at := 0
	for i, row := range rows {
		n := 1 + len(row.pokes) + 1 + dl
		if at+n > len(tw) || at+n > len(kn) || at+n > len(rb) {
			r.bad = append(r.bad, "output too short at row "+itoa(i))
			return r
		}
		for j := at; j < at+n; j++ {
			if tw[j] != rb[j] {
				r.bad = append(r.bad, "row "+itoa(i)+" twin/cruby: "+tw[j]+" | "+rb[j])
			}
		}
		if len(row.frame) >= 14 {
			r.both++
			for j := at; j < at+n; j++ {
				if tw[j] != kn[j] {
					r.bad = append(r.bad, "row "+itoa(i)+" (len "+itoa(len(row.frame))+") twin/kernel: "+tw[j]+" | "+kn[j])
					if k := strings.Index(tw[j], "]="); k > 0 {
						r.slots[tw[j][:k+1]]++
					} else {
						r.slots[strings.SplitN(tw[j], "=", 2)[0]]++
					}
				}
			}
		} else {
			r.short++
			if kn[at+1+len(row.pokes)] != "err=SpinelBPF::Other" {
				r.bad = append(r.bad, "row "+itoa(i)+": the kernel accepted short data")
			}
		}
		at += n
	}
	return r
}

// pktTable は source と行で harness を作り (kernel の実行 file は kbin — "" なら通常の build)、比べる。
func pktTable(t *testing.T, src string, rows []pktRow, h harnessSet) pktResult {
	t.Helper()
	cfg, _ := defaultConfig()
	text, _ := os.ReadFile(src)
	sp := frontend.Spinel{Bin: cfg.Spinel, LibDir: filepath.Join(cfg.Repo, "ruby", "lib")}
	res, err := frontend.Analyze(sp, t.TempDir(), src, string(text))
	if err != nil || res.Diags.Blocking() {
		t.Fatalf("analyze %s: %v %v", src, err, res.Diags)
	}
	script := pktScript(res.Programs[0].Name, rows)
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	rb := crubyFeed(t, script, h)
	if o := os.Getenv("E016_OUT"); o != "" {
		base := strings.TrimSuffix(filepath.Base(src), ".rb")
		os.WriteFile(filepath.Join(o, base+".script"), []byte(script), 0o644)
		os.WriteFile(filepath.Join(o, base+".kernel.out"), []byte(kn), 0o644)
	}
	return comparePkt(rows, dumpLines(res), tw, kn, rb)
}

func tPktSrc() string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "pkt", "t_pkt.rb")
}

// TestPacketTable は E016 の H1 (host、root): 4 つの packet の例 × 種 3 と t_pkt × 種 3 の表が一致する。
func TestPacketTable(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	pos := filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos")
	total, both, short := 0, 0, 0
	run := func(name, src string, rows []pktRow) {
		h := buildHarnesses(t, src)
		r := pktTable(t, src, rows, h)
		total, both, short = total+r.rows, both+r.both, short+r.short
		t.Logf("%s: %d rows (%d three-way, %d twin-only), %d mismatches", name, r.rows, r.both, r.short, len(r.bad))
		for _, b := range first(r.bad, 5) {
			t.Error(b)
		}
	}
	for _, name := range []string{"pkt_ether", "pkt_nested", "pkt_bounds", "pkt_off_masked"} {
		var rows []pktRow
		for s := 0; s < 3; s++ {
			rows = append(rows, pktRows(name, s)...)
		}
		run(name, filepath.Join(pos, name+".rb"), rows)
	}
	var rows []pktRow
	for s := 0; s < 3; s++ {
		rows = append(rows, tPktRows(s)...)
	}
	run("t_pkt", tPktSrc(), rows)
	t.Logf("total: %d rows (%d three-way, %d twin-only)", total, both, short)
	if total < 1000 {
		t.Errorf("want at least 1000 rows, got %d", total)
	}
}

// mutatedPkt は src の .mlir を書き換えて kernel の harness を作り直す (ebpf-compile の誤りは返す — M1 の検出器)。
func mutatedPkt(t *testing.T, src string, rewrite func(string) (string, bool)) (harnessSet, error) {
	t.Helper()
	h := buildHarnesses(t, src)
	cfg, _ := defaultConfig()
	name := strings.TrimSuffix(filepath.Base(src), ".rb")
	d := filepath.Dir(h.kernelBin)
	ksrc := filepath.Join(d, name+".rb")
	m, err := os.ReadFile(filepath.Join(d, name+".mlir"))
	if err != nil {
		t.Fatal(err)
	}
	mm, ok := rewrite(string(m))
	if !ok || mm == string(m) {
		t.Fatalf("the rewrite did not apply to %s.mlir", name)
	}
	os.WriteFile(filepath.Join(d, name+".mlir"), []byte(mm), 0o644)
	if err := runIn(d, cfg.EbpfCompile, name+".mlir", "--schema", name+".schema.json", "-o", name+".bpf.o"); err != nil {
		return h, err
	}
	schema, _ := os.ReadFile(filepath.Join(d, name+".schema.json"))
	sha, err := checkSchemaSHA(filepath.Join(d, name+".bpf.o"), schema)
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(d, name+"_embed.S"), []byte(embedAsm(name+".bpf.o", sha, name+".maps.json")), 0o644)
	if err := runIn(d, cfg.Clang, "-c", "-x", "assembler", name+"_embed.S", "-o", name+"_embed.o"); err != nil {
		t.Fatal(err)
	}
	mut := filepath.Join(d, "kernel_mut")
	if err := Link(cfg, ksrc, mut); err != nil {
		t.Fatal(err)
	}
	h.kernelBin = mut
	return h, nil
}

// markerLoc は src の marker の行の loc の接頭辞 (`loc("t_pkt.rb":L:`)。
func markerLoc(src, marker string) string {
	b, _ := os.ReadFile(src)
	for i, l := range strings.Split(string(b), "\n") {
		if strings.Contains(l, marker) {
			return "loc(\"" + filepath.Base(src) + "\":" + itoa(i+1) + ":"
		}
	}
	return "<no marker " + marker + ">"
}

// atLoc は loc の行の op の old を new に (1 つだけ)。region を持つ op (ebpf.packet.check・ebpf.if・ebpf.ref.check) の loc は op の行でなく
// region を閉じる `}` の後に付く (MLIR の表記 — E016 の 1 回目の試験の誤り) — その op の書き換えは loc で選べない。
func atLoc(tag, old, new string) func(string) (string, bool) {
	return func(s string) (string, bool) {
		lines := strings.Split(s, "\n")
		for i, l := range lines {
			if strings.Contains(l, tag) && strings.Contains(l, old) {
				lines[i] = strings.Replace(l, old, new, 1)
				return strings.Join(lines, "\n"), true
			}
		}
		return s, false
	}
}

func chain(fs ...func(string) (string, bool)) func(string) (string, bool) {
	return func(s string) (string, bool) {
		for _, f := range fs {
			var ok bool
			if s, ok = f(s); !ok {
				return s, false
			}
		}
		return s, true
	}
}

// dropFromBE は loc の行の from_be を使わない形に (結果の使い手 extui の operand を from_be の入力に — from_be は使われずに残る)。
func dropFromBE(tag string) func(string) (string, bool) {
	return func(s string) (string, bool) {
		lines := strings.Split(s, "\n")
		for i, l := range lines {
			if !strings.Contains(l, tag) || !strings.Contains(l, "ebpf.byteorder.from_be") {
				continue
			}
			f := strings.Fields(l) // %a = ebpf.byteorder.from_be %b : i16 loc
			res, arg := f[0], f[3]
			for j := i + 1; j < len(lines); j++ {
				if strings.Contains(lines[j], "arith.extui "+res+" ") {
					lines[j] = strings.Replace(lines[j], "arith.extui "+res+" ", "arith.extui "+arg+" ", 1)
					return strings.Join(lines, "\n"), true
				}
			}
		}
		return s, false
	}
}

// TestPacketMutations は E016 の H2 (host、root): 変異 M1〜M5 の検出器 (ebpf-compile か差動) と、差動の不一致の slot。
func TestPacketMutations(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	src := tPktSrc()
	var rows []pktRow
	for s := 0; s < 3; s++ {
		rows = append(rows, tPktRows(s)...)
	}
	for _, m := range []struct {
		name    string
		rewrite func(string) (string, bool)
		slot    string // 差動の不一致の slot の期待 ("" は ebpf-compile の拒否)
	}{
		{"M1 len 6 -> 5", chain(func(s string) (string, bool) { // packet.check の行は loc を持たない (loc は region を閉じる行) — 長さ 6 の窓は t_pkt に 1 つだけ
			return strings.Replace(s, "] len 6 :", "] len 5 :", 1), strings.Count(s, "] len 6 :") == 1
		}, func(s string) (string, bool) {
			return strings.ReplaceAll(s, "!ebpf.pkt_window<6>", "!ebpf.pkt_window<5>"), strings.Contains(s, "!ebpf.pkt_window<6>")
		}), ""},
		{"M2 drop from_be (be16)", dropFromBE(markerLoc(src, "# M2")), "Out[4]"},
		{"M3 offset 14 -> 15", atLoc(markerLoc(src, "# M3"), "arith.constant 14 : i64", "arith.constant 15 : i64"), "Out[14]"},
		{"M4 swap the arms' values", chain(atLoc(markerLoc(src, "# M4a"), "arith.constant 1 : i64", "arith.constant 2 : i64"), atLoc(markerLoc(src, "# M4b"), "arith.constant 2 : i64", "arith.constant 1 : i64")), "Out[13]"},
		{"M5 extui -> extsi (u8)", atLoc(markerLoc(src, "# M5"), "arith.extui", "arith.extsi"), "Out[8]"},
	} {
		h, cerr := mutatedPkt(t, src, m.rewrite)
		if m.slot == "" {
			if cerr == nil || !strings.Contains(cerr.Error(), "window") {
				t.Errorf("%s: want ebpf-compile to refuse the window read, got %v", m.name, cerr)
			} else {
				t.Logf("%s: detector ebpf-compile — %s", m.name, firstLines(cerr.Error(), 3))
			}
			continue
		}
		if cerr != nil {
			t.Errorf("%s: ebpf-compile refused: %v", m.name, cerr)
			continue
		}
		r := pktTable(t, src, rows, h)
		t.Logf("%s: detector differential — %d mismatching lines, slots %v", m.name, len(r.bad), r.slots)
		if len(r.bad) == 0 || r.slots[m.slot] == 0 {
			t.Errorf("%s: want mismatches in %s, got %v", m.name, m.slot, r.slots)
		}
	}
}
