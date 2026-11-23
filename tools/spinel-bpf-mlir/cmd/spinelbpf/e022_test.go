package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E022 の試験: record の差動と変異 (P006 §4)。

// TestRecordHarnessSmoke は E022 の H1 (host、root): rec_basic の twin (Spinel)・kernel・CRuby の harness が build でき、小さな手順で一致する。
func TestRecordHarnessSmoke(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	src := filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "rec_basic.rb")
	h := buildHarnesses(t, src)
	script := "reset\npoke Stats 0 hits 5\npoke Stats 0 flags -9\npoke Pairs 1 a -3\npoke Pairs 1 b 70\nrun prog\ndump\nrun prog\ndump\n"
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	rb := crubyFeed(t, script, h)
	t.Logf("twin:\n%s", tw)
	if tw != kn {
		t.Errorf("twin and kernel differ\n--- kernel\n%s", kn)
	}
	if tw != rb {
		t.Errorf("twin and CRuby differ\n--- cruby\n%s", rb)
	}
	if !strings.Contains(tw, "Stats[0].hits=7") {
		t.Errorf("want hits 5 + 1 + 1")
	}
}

func tRecSrc() string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "rec", "t_rec.rb")
}

// tRecScript は t_rec の表 (期待の値を持たない): In の 2 つの値 × Ws[1] の atomic の基の値 × Ps[1] の poke。行ごとに reset・poke 6・run・dump。
func tRecScript() (string, int) {
	xs := []string{"0", "1", "127", "128", "255", "256", "65535", "65536", "2147483647", "2147483648", "4294967295", "4294967296", "-1", "-2147483648", "9223372036854775807", "-9223372036854775807"}
	ys := []string{"0", "-1", "9223372036854775807", "-9223372036854775807"}
	bases := [][2]string{{"0", "2147483647"}, {"4294967295", "-2147483648"}}
	var b strings.Builder
	rows := 0
	for i, x := range xs {
		for _, y := range ys {
			for j, bs := range bases {
				pa := []string{"0", "255"}[(i+j)%2]
				pb := []string{"-32768", "32767", "-1"}[(i+j)%3]
				fmt.Fprintf(&b, "reset\npoke In 0 %s\npoke In 1 %s\npoke Ws 1 u32 %s\npoke Ws 1 i32 %s\npoke Ps 1 a %s\npoke Ps 1 b %s\nrun t\ndump\n", x, y, bs[0], bs[1], pa, pb)
				rows++
			}
		}
	}
	return b.String(), rows
}

// recTable は t_rec の harness の出力 (twin・kernel・CRuby) を行ごとに比べる — 1 行は 1 + 6 + 1 + dump の行。不一致の dump の行の名前を数える。
func recTable(t *testing.T, h harnessSet, script string, rows int) (int, map[string]int, []string) {
	t.Helper()
	tw := strings.Split(feed(t, false, script, h.twinBin), "\n")
	kn := strings.Split(feed(t, true, script, h.kernelBin), "\n")
	rb := strings.Split(crubyFeed(t, script, h), "\n")
	per := len(tw) / rows
	if len(tw) != len(kn) || len(tw) != len(rb) || per*rows+1 != len(tw) {
		t.Fatalf("output lengths differ: twin %d kernel %d cruby %d (rows %d)", len(tw), len(kn), len(rb), rows)
	}
	slots := map[string]int{}
	var bad []string
	for i := range tw {
		if tw[i] != rb[i] {
			bad = append(bad, fmt.Sprintf("row %d twin/cruby: %s | %s", i/per, tw[i], rb[i]))
		}
		if tw[i] != kn[i] {
			bad = append(bad, fmt.Sprintf("row %d twin/kernel: %s | %s", i/per, tw[i], kn[i]))
			slots[strings.SplitN(tw[i], "=", 2)[0]]++
		}
	}
	return per, slots, bad
}

// TestRecordTable は E022 の H2 (host、root): t_rec の表で twin (Spinel)・kernel・CRuby が全ての行で一致。
func TestRecordTable(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildHarnesses(t, tRecSrc())
	script, rows := tRecScript()
	per, _, bad := recTable(t, h, script, rows)
	t.Logf("%d rows (%d lines each), %d mismatching lines", rows, per, len(bad))
	for _, x := range first(bad, 10) {
		t.Error(x)
	}
}

// TestRecordTableOut は E022 の成果物: 表の kernel の出力を E022_OUT に残す (値の多様さの確認用)。
func TestRecordTableOut(t *testing.T) {
	parallel(t) // P018 E075
	o := os.Getenv("E022_OUT")
	if o == "" {
		t.Skip("E022_OUT")
	}
	h := buildHarnesses(t, tRecSrc())
	script, _ := tRecScript()
	os.WriteFile(filepath.Join(o, "t_rec.script"), []byte(script), 0o644)
	os.WriteFile(filepath.Join(o, "t_rec.kernel.out"), []byte(feed(t, true, script, h.kernelBin)), 0o644)
}

// mutatedRec は t_rec の kernel の harness を .mlir と schema の書き換えで作り直す (埋め込みの schema の SHA の行だけを差し替え — record の表は保つ)。
// ebpf-compile の誤りは返す。
func mutatedRec(t *testing.T, rewriteMLIR, rewriteSchema func(string) (string, bool)) (harnessSet, error) {
	t.Helper()
	h := buildHarnesses(t, tRecSrc())
	cfg, _ := defaultConfig()
	d := filepath.Dir(h.kernelBin)
	for _, f := range []struct {
		name string
		rw   func(string) (string, bool)
	}{{"t_rec.mlir", rewriteMLIR}, {"t_rec.schema.json", rewriteSchema}} {
		if f.rw == nil {
			continue
		}
		b, _ := os.ReadFile(filepath.Join(d, f.name))
		m, ok := f.rw(string(b))
		if !ok || m == string(b) {
			t.Fatalf("the rewrite did not apply to %s", f.name)
		}
		os.WriteFile(filepath.Join(d, f.name), []byte(m), 0o644)
	}
	if err := runIn(d, cfg.EbpfCompile, "t_rec.mlir", "--schema", "t_rec.schema.json", "-o", "t_rec.bpf.o"); err != nil {
		return h, err
	}
	schema, _ := os.ReadFile(filepath.Join(d, "t_rec.schema.json"))
	sha, err := checkSchemaSHA(filepath.Join(d, "t_rec.bpf.o"), schema)
	if err != nil {
		t.Fatal(err)
	}
	emb, _ := os.ReadFile(filepath.Join(d, "t_rec_embed.S"))
	lines := strings.Split(string(emb), "\n")
	for i, l := range lines {
		if strings.HasPrefix(l, "spinelbpf_schema_sha:") {
			lines[i+1] = fmt.Sprintf("  .asciz %q", sha)
		}
	}
	os.WriteFile(filepath.Join(d, "t_rec_embed.S"), []byte(strings.Join(lines, "\n")), 0o644)
	if err := runIn(d, cfg.Clang, "-c", "-x", "assembler", "t_rec_embed.S", "-o", "t_rec_embed.o"); err != nil {
		t.Fatal(err)
	}
	mut := filepath.Join(d, "kernel_mut")
	if err := Link(cfg, filepath.Join(d, "t_rec.rb"), mut); err != nil {
		t.Fatal(err)
	}
	h.kernelBin = mut
	return h, nil
}

// TestRecordMutations は E022 の H3 (host、root): 変異の対照の検出器の列と不一致の slot。
func TestRecordMutations(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	src := tRecSrc()
	script, rows := tRecScript()
	for _, m := range []struct {
		name         string
		mlir, schema func(string) (string, bool)
		slot         string // 差動の不一致の slot の接頭辞 ("load" は load の段 2' の MapMismatch、"compile" は ebpf-compile)
	}{
		{"M1 schema W.i8 offset 29 -> 30", nil, func(s string) (string, bool) {
			o := "\"name\": \"i8\",\n            \"offset\": 29,"
			return strings.Replace(s, o, "\"name\": \"i8\",\n            \"offset\": 30,", 1), strings.Contains(s, o)
		}, "load"},
		{"M2 record.make names swapped (Q)", atLoc(markerLoc(src, "# MM"), `["x", "y"]`, `["y", "x"]`), nil, "Qs[0]"},
		{"M3 extsi -> extui (i8 read)", atLoc(markerLoc(src, "# MX"), "arith.extsi", "arith.extui"), nil, "Out[0]"},
		{"M4 field.store u16 -> i16", atLoc(markerLoc(src, "# MS"), `"u16"`, `"i16"`), nil, "Ws[0]"},
		{"M5 atomic_add delta 1 -> 2", atLoc(markerLoc(src, "# MA"), "arith.constant 1 : i32", "arith.constant 2 : i32"), nil, "Ws[2].u32"},
	} {
		h, cerr := mutatedRec(t, m.mlir, m.schema)
		if cerr != nil {
			if m.slot != "compile" {
				t.Errorf("%s: ebpf-compile refused: %v", m.name, cerr)
			} else {
				t.Logf("%s: detector ebpf-compile — %s", m.name, firstLines(cerr.Error(), 2))
			}
			continue
		}
		if m.slot == "load" {
			cmd := sudoCmd(t, h.kernelBin)
			cmd.Stdin = strings.NewReader("reset\n")
			out, err := cmd.CombinedOutput()
			if err == nil || !strings.Contains(string(out), "MapMismatch") {
				t.Errorf("%s: want a MapMismatch at load, got err=%v\n%s", m.name, err, firstLines(string(out), 4))
			} else {
				t.Logf("%s: detector load (bindrt records) — %s", m.name, firstLines(strings.TrimSpace(string(out)), 2))
			}
			continue
		}
		_, slots, bad := recTable(t, h, script, rows)
		hit := 0
		for k, v := range slots {
			if strings.HasPrefix(k, m.slot) {
				hit += v
			}
		}
		t.Logf("%s: detector differential — %d mismatching lines, slots %v", m.name, len(bad), slots)
		if hit == 0 {
			t.Errorf("%s: want mismatches in %s", m.name, m.slot)
		}
	}
}
