package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// E010 の試験: 表駆動の差動 (P002 §3.3) と変異の対照 (§3.4 の text の書き換え)。hook の変異は e010_mutation_test.go (build tag)。
//
// 比較の規則 (P001 §3.8 の INT64_MIN の規則の一般の形):
//   - Spinel の表: CRuby の出力に −2^63 が無い行で、twin (Spinel の native) と kernel の出力が全て一致
//   - CRuby の表: 全ての行で kernel と CRuby の twin が一致 — CRuby の −2^63 は kernel の `err=SpinelBPF::ValueRange` と対応させる
//     (kernel の map_get は −2^63 を Integer で返せない — E009)

const int64MinText = "-9223372036854775808"

var tableValues = map[string][]string{
	"t_i32":  {"0", "1", "-1", "-2147483648", "2147483647", "-2147483647", "2147483646", "65536", "1431655765", "-1431655766", "7", "-7"},
	"t_i32b": {"0", "1", "-1", "-2147483648", "2147483647", "-2147483647", "2147483646", "65536", "1431655765", "-1431655766", "7", "-7"},
	"t_u32":  {"0", "1", "4294967295", "2147483648", "2147483647", "2863311530", "7"},
	"t_i64":  {"0", "1", "-1", "-9223372036854775807", "9223372036854775807", "9223372036854775806", "4611686018427387904", "-4611686018427387904", "6148914691236517205", "-7"},
	"t_u64":  {"0", "1", "9223372036854775807", "4611686018427387904", "6148914691236517205"},
	"t_min":  nil,
}

// tableScript は表の行の命令の列と行の数。2 入力の表は (a, b) の全ての組、t_u64 は 1 入力、t_min は入力なし。
func tableScript(name string) (string, int) {
	vals := tableValues[name]
	var b strings.Builder
	rows := 0
	switch {
	case vals == nil:
		b.WriteString("reset\nrun prog\ndump\n")
		rows = 1
	case name == "t_u64":
		for _, a := range vals {
			fmt.Fprintf(&b, "reset\npoke In 0 %s\nrun prog\ndump\n", a)
			rows++
		}
	default:
		for _, a := range vals {
			for _, c := range vals {
				fmt.Fprintf(&b, "reset\npoke In 0 %s\npoke In 1 %s\nrun prog\ndump\n", a, c)
				rows++
			}
		}
	}
	return b.String(), rows
}

func splitRows(t *testing.T, out string, rows int) [][]string {
	t.Helper()
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if rows == 0 || len(lines)%rows != 0 {
		t.Fatalf("%d lines do not split into %d rows:\n%s", len(lines), rows, out)
	}
	per := len(lines) / rows
	var r [][]string
	for i := 0; i < rows; i++ {
		r = append(r, lines[i*per:(i+1)*per])
	}
	return r
}

// tableResult は 1 つの表の比較の結果。
type tableResult struct {
	rows, spinelRows, minRows int
	spinelBad, crubyBad       []string // 不一致の行 (入力と slot)
}

func compareTable(t *testing.T, name, script string, rows int, twin, kernel, cruby string) tableResult {
	t.Helper()
	tw, kn, rb := splitRows(t, twin, rows), splitRows(t, kernel, rows), splitRows(t, cruby, rows)
	cmds := strings.Split(strings.TrimRight(script, "\n"), "\n")
	per := len(cmds) / rows
	res := tableResult{rows: rows}
	crubyOn := os.Getenv("SPINELBPF_CRUBY") == "1"
	for i := 0; i < rows; i++ {
		input := strings.Join(cmds[i*per:(i+1)*per], "; ")
		hasMin := false
		for _, l := range rb[i] {
			if crubyOn && strings.HasSuffix(l, "="+int64MinText) {
				hasMin = true
			}
		}
		// CRuby の差動を外している間 (利用者の決定 2026-09-27) は −2^63 の行を S1 の形そのもので外す: 同じ枠で双子が nil の印 (`X=` の空の値 — Spinel の Integer は −2^63 を
		// nil で表す) を出し kernel の読みが `X=err=SpinelBPF::ValueRange`。kernel の ValueRange だけでは外さない — 溢れの検査を外す変異 (TestHookNoOverflow) の行は
		// kernel が wrap の −2^63 で ValueRange でも双子は RangeError で、外すと検出の力が落ちる (E042 の 2 回目の gate が捕まえた)
		for j := range kn[i] {
			if !crubyOn && j < len(tw[i]) && strings.HasSuffix(tw[i][j], "=") && kn[i][j] == tw[i][j]+"err=SpinelBPF::ValueRange" {
				hasMin = true
			}
		}
		if hasMin {
			res.minRows++
		} else {
			res.spinelRows++
			for j := range tw[i] {
				if tw[i][j] != kn[i][j] {
					res.spinelBad = append(res.spinelBad, fmt.Sprintf("[%s] twin %q kernel %q", input, tw[i][j], kn[i][j]))
				}
			}
		}
		for j := range rb[i] {
			if !crubyOn {
				break
			}
			k, c := kn[i][j], rb[i][j]
			if k == c {
				continue
			}
			if strings.HasSuffix(c, "="+int64MinText) && k == strings.TrimSuffix(c, int64MinText)+"err=SpinelBPF::ValueRange" {
				continue
			}
			res.crubyBad = append(res.crubyBad, fmt.Sprintf("[%s] cruby %q kernel %q", input, c, k))
		}
	}
	return res
}

// runTable は表の program の twin・kernel (root)・CRuby の harness に同じ命令の列を流して比べる。kernelBin を渡すと (変異) それを使う。
func runTable(t *testing.T, name string, h harnessSet) tableResult {
	t.Helper()
	script, rows := tableScript(name)
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	rb := crubyFeed(t, script, h)
	return compareTable(t, name, script, rows, tw, kn, rb)
}

func tableSrc(name string) string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "table", name+".rb")
}

// TestTableDifferential は E010 の H1・H2: 5 つの表の全ての行 (host 7.1.8)。
func TestTableDifferential(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	total := 0
	for _, name := range []string{"t_i32", "t_i32b", "t_u32", "t_i64", "t_u64", "t_min"} {
		t.Run(name, func(t *testing.T) {
			if name == "t_min" && os.Getenv("SPINELBPF_CRUBY") != "1" {
				t.Skip("t_min は −2^63 の literal の表 — 双子は S1 で表せず、CRuby との差で記録する表 (CRuby の差動は一時的に外している — SPINELBPF_CRUBY=1 で走る)")
			}
			start := time.Now()
			h := buildHarnesses(t, tableSrc(name))
			r := runTable(t, name, h)
			total += r.rows
			t.Logf("%s: %d rows (Spinel table %d, rows with −2^63 %d) in %v — Spinel mismatches %d, CRuby mismatches %d",
				name, r.rows, r.spinelRows, r.minRows, time.Since(start).Round(time.Millisecond), len(r.spinelBad), len(r.crubyBad))
			for _, b := range append(r.spinelBad, r.crubyBad...) {
				t.Log(b)
			}
			if len(r.spinelBad) > 0 || len(r.crubyBad) > 0 {
				t.Fail()
			}
		})
	}
	t.Logf("total rows: %d", total)
}

// TestINT64MinSpinelTwin は E010 の H2 の後半 (記録): t_min で Spinel の twin は CRuby と違う行を出す (S1 — −2^63 を nil として扱う)。
func TestINT64MinSpinelTwin(t *testing.T) {
	parallel(t) // P018 E075
	if os.Getenv("SPINELBPF_CRUBY") != "1" {
		t.Skip("CRuby の差動は一時的に外している (利用者の決定 2026-09-27 — SPINELBPF_CRUBY=1 で走る)")
	}
	h := buildHarnesses(t, tableSrc("t_min"))
	script, _ := tableScript("t_min")
	tw := feed(t, false, script, h.twinBin)
	rb := crubyFeed(t, script, h)
	twl, rbl := strings.Split(tw, "\n"), strings.Split(rb, "\n")
	var diff []string
	for i := range rbl {
		if i < len(twl) && twl[i] != rbl[i] {
			diff = append(diff, fmt.Sprintf("spinel %q cruby %q", twl[i], rbl[i]))
		}
	}
	t.Logf("Spinel twin vs CRuby on t_min: %d differing lines\n%s", len(diff), strings.Join(diff, "\n"))
	if len(diff) == 0 {
		t.Fatal("expected the Spinel twin to differ from CRuby on −2^63 (S1)")
	}
}

// mutatedKernel は表の program の kernel の harness を、.mlir の text を書き換えて build する (E010 の H3 — 本番の code に何も入らない)。
func mutatedKernel(t *testing.T, name string, rewrite func(string) (string, bool)) harnessSet {
	t.Helper()
	h := buildHarnesses(t, tableSrc(name))
	cfg, _ := defaultConfig()
	d := filepath.Dir(h.kernelBin)
	src := filepath.Join(d, name+".rb")
	m, err := os.ReadFile(filepath.Join(d, name+".mlir"))
	if err != nil {
		t.Fatal(err)
	}
	mm, ok := rewrite(string(m))
	if !ok || mm == string(m) {
		t.Fatalf("the rewrite did not apply to %s.mlir", name)
	}
	os.WriteFile(filepath.Join(d, name+".mlir"), []byte(mm), 0o644)
	schema, _ := os.ReadFile(filepath.Join(d, name+".schema.json"))
	if err := runIn(d, cfg.EbpfCompile, name+".mlir", "--schema", name+".schema.json", "-o", name+".bpf.o"); err != nil {
		t.Fatal(err)
	}
	sha, err := checkSchemaSHA(filepath.Join(d, name+".bpf.o"), schema)
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(d, name+"_embed.S"), []byte(embedAsm(name+".bpf.o", sha, name+".maps.json")), 0o644)
	if err := runIn(d, cfg.Clang, "-c", "-x", "assembler", name+"_embed.S", "-o", name+"_embed.o"); err != nil {
		t.Fatal(err)
	}
	mut := filepath.Join(d, "kernel_mut")
	if err := Link(cfg, src, mut); err != nil {
		t.Fatal(err)
	}
	h.kernelBin = mut
	return h
}

// replaceFirst は最初の 1 つを置き換える。
func replaceFirst(old, new string) func(string) (string, bool) {
	return func(s string) (string, bool) {
		if !strings.Contains(s, old) {
			return s, false
		}
		return strings.Replace(s, old, new, 1), true
	}
}

// replaceAtLine は source の marker の行の loc を持つ op だけを書き換える (region を持つ op の loc は閉じる `}` の後 — その op 自身は選べない、E016) (E010 の 1 回目: 最初の op を書き換えると、除数 1 の等価な変異や
// floor の剰余の展開の中の cmpi を書き換え、意図した op に当たらなかった)。
func replaceAtLine(old, new, table, marker string) func(string) (string, bool) {
	return func(s string) (string, bool) {
		src, err := os.ReadFile(tableSrc(table))
		if err != nil {
			return s, false
		}
		line := 0
		for i, l := range strings.Split(string(src), "\n") {
			if strings.Contains(l, marker) {
				line = i + 1
			}
		}
		if line == 0 {
			return s, false
		}
		tag := fmt.Sprintf("loc(%q:%d:", table+".rb", line)
		lines := strings.Split(s, "\n")
		for i, l := range lines {
			if strings.Contains(l, old) && strings.Contains(l, tag) {
				lines[i] = strings.Replace(l, old, new, 1)
				return strings.Join(lines, "\n"), true
			}
		}
		return s, false
	}
}

// TestTextMutations は E010 の H3: .mlir の書き換え 7 つのそれぞれで表が落ち、不一致の行に意図した slot が在る。
func TestTextMutations(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cases := []struct {
		name, table string
		rewrite     func(string) (string, bool)
		slot        string // 不一致に含まれるべき slot
	}{
		{"shrsi to shrui", "t_i32", replaceFirst("arith.shrsi", "arith.shrui"), "Out[11]"},
		{"extsi to extui", "t_i32", replaceFirst("arith.extsi", "arith.extui"), "Out[0]"},
		{"floordivsi to divsi", "t_i32", replaceAtLine("arith.floordivsi", "arith.divsi", "t_i32", "Out.update(15,"), "Out[15]"},
		{"floor mod select arms swapped", "t_i32", func(s string) (string, bool) {
			i := strings.Index(s, "arith.select")
			if i < 0 {
				return s, false
			}
			// `%m = arith.select %fix, %rd, %r : i64` の 2 つの値を入れ替える
			line := s[i : i+strings.Index(s[i:], "\n")]
			f := strings.SplitN(line, ", ", 3)
			if len(f) != 3 {
				return s, false
			}
			rest := strings.SplitN(f[2], " : ", 2)
			swapped := f[0] + ", " + rest[0] + ", " + f[1] + " : " + rest[1]
			return strings.Replace(s, line, swapped, 1), true
		}, "Out[17]"},
		{"cmpi slt to ult", "t_i32b", replaceAtLine("arith.cmpi slt", "arith.cmpi ult", "t_i32b", "Out.update(23,"), "Out[23]"},
		{"subi operands swapped", "t_i32", func(s string) (string, bool) {
			i := strings.Index(s, "arith.subi ")
			if i < 0 {
				return s, false
			}
			line := s[i : i+strings.Index(s[i:], " : ")]
			ops := strings.SplitN(strings.TrimPrefix(line, "arith.subi "), ", ", 2)
			return strings.Replace(s, line, "arith.subi "+ops[1]+", "+ops[0], 1), true
		}, "Out[1]"},
		{"andi mask bit flipped", "t_i64", replaceFirst("arith.constant 255 : i64", "arith.constant 254 : i64"), "Out[2]"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := mutatedKernel(t, tc.table, tc.rewrite)
			r := runTable(t, tc.table, h)
			bad := append(r.spinelBad, r.crubyBad...)
			t.Logf("%d mismatching lines (Spinel %d, CRuby %d); first: %v", len(bad), len(r.spinelBad), len(r.crubyBad), first(bad, 3))
			if len(bad) == 0 {
				t.Fatal("the mutation was not caught by the table")
			}
			hit := false
			for _, b := range bad {
				if strings.Contains(b, "\""+tc.slot+"=") {
					hit = true
				}
			}
			if !hit {
				t.Errorf("no mismatch at the intended slot %s", tc.slot)
			}
		})
	}
}

func first(s []string, n int) []string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

// TestNoMutationHookInProduction は E010 の H5: 既定の build の spinelbpf で i64 の a + b は SB014、実行 file に mutation の hook の文字列が無い。
func TestNoMutationHookInProduction(t *testing.T) {
	parallel(t) // P018 E075
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d := t.TempDir()
	src := filepath.Join(d, "t_hook.rb")
	os.WriteFile(src, []byte(hookProgram), 0o644)
	if _, err := Build(cfg, src); err == nil || !strings.Contains(err.Error(), "SB014") {
		t.Fatalf("want SB014 for the unproven i64 a + b, got %v", err)
	}
	bin := filepath.Join(d, "spinelbpf")
	b := exec.Command(cfg.Go, append(append([]string{"build"}, formBuildArgs...), "-o", bin, "./cmd/spinelbpf")...) // E161 追補 2: 形の製品
	b.Dir = cfg.Repo
	if o, err := b.CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, o)
	}
	data, _ := os.ReadFile(bin)
	for _, s := range []string{"SPINELBPF_MUTATION", "swap-operands", "no-offset-range", "no-rmw"} {
		if strings.Contains(string(data), s) {
			t.Errorf("the production spinelbpf contains %q", s)
		}
	}
}

// hookProgram は区間の証明が拒否する i64 の a + b (hook の変異の試験)。
const hookProgram = `require "bpf"

In = BPF::ArrayMap.new("In", :i64, 2)
Out = BPF::ArrayMap.new("Out", :i64, 1)

def prog(ctx)
  a = 0
  b = 0
  p = In.lookup(0)
  if p
    a = p.load
  end
  q = In.lookup(1)
  if q
    b = q.load
  end
  Out.update(0, a + b)
  BPF::XDP_PASS
end
BPF.xdp :prog
`
