package main

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// E060 の試験: 有界の loop (P015) の .mlir の形・host の kernel の load・ebpf-compile の展開の見積もりの誤りの SB030 への包み。

// loopMLIR は正の例を build して .mlir を返す (build の失敗は誤り)。
func loopMLIR(t *testing.T, cfg Config, name, extra string) (string, string) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", name+".rb"))
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e060-")
	if err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(d, name+".rb")
	os.WriteFile(src, append(b, []byte(extra)...), 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	m, err := os.ReadFile(filepath.Join(d, name+".mlir"))
	if err != nil {
		t.Fatal(err)
	}
	return string(m), src
}

var loopLine = regexp.MustCompile(`ebpf\.loop (\d+)( unroll)?( bound\()?`)

// clampIf は bound の前の負の下端の clamp — 結果が直後に i32 へ trunci される ebpf.if (add_or_init の展開の ebpf.if と分ける)
var clampIf = regexp.MustCompile(`(%v\d+) = ebpf\.if %v\d+ -> i64 \{\n(?:[^\n]*\n){4}\s*%v\d+ = arith\.trunci %v\d+ : i64 to i32`)

// TestLoopShapes は E060 の H1 と H6 の (U): 正の例の loop の N・bound・clamp・break / continue、全ての loop が unroll。
func TestLoopShapes(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name   string
		loops  []string // "N" か "N bound" を出現の順に
		clamps int
		has    []string
	}{
		{"loop_times", []string{"4", "8", "8"}, 0, nil},
		{"loop_bound", []string{"15 bound", "11 bound", "64"}, 1, nil},
		{"loop_break_next", []string{"8", "16"}, 0, []string{"ebpf.break ", "ebpf.continue "}},
		{"loop_nested", []string{"8", "8"}, 0, []string{"ebpf.continue "}},
		{"loop_map", []string{"4"}, 0, []string{"ebpf.map.atomic_add", "ebpf.map.try_update", "ebpf.ref.check", "ebpf.global.atomic_add"}},
		{"loop_window", []string{"8"}, 0, []string{"ebpf.packet.check", "ebpf.packet.window_load", "ebpf.break "}}, // E061
	} {
		m, _ := loopMLIR(t, cfg, c.name, "")
		var got []string
		for _, x := range loopLine.FindAllStringSubmatch(m, -1) {
			if x[2] == "" {
				t.Errorf("%s: a loop without unroll: %s", c.name, x[0])
			}
			s := x[1]
			if x[3] != "" {
				s += " bound"
			}
			got = append(got, s)
		}
		if strings.Join(got, ",") != strings.Join(c.loops, ",") {
			t.Errorf("%s: loops %v, want %v", c.name, got, c.loops)
		}
		if n := len(clampIf.FindAllString(m, -1)); n != c.clamps {
			t.Errorf("%s: %d clamp ebpf.if, want %d", c.name, n, c.clamps)
		}
		for _, h := range c.has {
			if !strings.Contains(m, h) {
				t.Errorf("%s: no %q", c.name, h)
			}
		}
	}
}

// TestLoopHostLoad は E060 の H1 (root): 正の例の ELF が host の kernel (7.1.8) の照合付きの load を通る。
func TestLoopHostLoad(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"loop_times", "loop_bound", "loop_break_next", "loop_nested", "loop_map", "loop_window"} {
		_, src := loopMLIR(t, cfg, name, "\nrequire \"spinelbpf\"\nobj = SpinelBPF.load_embedded\nputs \"loaded unmet=#{obj.unmet.length}\"\nobj.close\n")
		exe := strings.TrimSuffix(src, ".rb")
		if err := Link(cfg, src, exe); err != nil {
			t.Fatal(err)
		}
		out := feed(t, true, "", exe)
		if !strings.Contains(out, "loaded unmet=0") {
			t.Fatalf("%s: %s", name, out)
		}
		t.Logf("%s: %s", name, strings.TrimSpace(out))
	}
}

// TestLoopBudgetWrapped は E060 の H4: 64 回 × map の atomic_add 12 個 — frontend は通り、ebpf-compile の展開の見積もりの誤りを build が SB030 の 1 つ (loop の位置) に包む。
func TestLoopBudgetWrapped(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "loop", "budget.rb"))
	if err != nil {
		t.Fatal(err)
	}
	d := t.TempDir()
	src := filepath.Join(d, "budget.rb")
	os.WriteFile(src, b, 0o644)
	_, err = Build(cfg, src)
	var fe *frontend.Error
	if !errors.As(err, &fe) || len(fe.Diags) != 1 {
		t.Fatalf("want one wrapped diagnostic, got %v", err)
	}
	dg := fe.Diags[0]
	if dg.Code != frontend.SB030LoopShape || dg.Verdict != frontend.Rejected || dg.Pos.String() != "budget.rb:7:3" || !strings.Contains(dg.Msg, "4096") {
		t.Errorf("got %s", dg)
	}
	t.Log(dg)
}

// TestUnrollBudgetMessage は E060 のレビューの P3: 今の bpf-mlir の ebpf-compile の展開の見積もりの誤りの文が budgetMsg に一致する
// (鍵で skip しない — 毎回の gate で。bpf-mlir の版を上げて文が変われば、包みが黙って元の誤りに戻る前にここで落ちる)。
// 入力は budget.rb の生成物の .mlir と schema の写し (frontend を通さず ebpf-compile だけ — 速い)。
func TestUnrollBudgetMessage(t *testing.T) {
	parallel(t) // P018 E075
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d := t.TempDir()
	for _, f := range []string{"budget.mlir", "budget.schema.json"} {
		b, err := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "loop", f))
		if err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(d, f), b, 0o644)
	}
	_, err = compileELF(cfg, d, "budget")
	var fe *frontend.Error
	if !errors.As(err, &fe) || len(fe.Diags) != 1 || fe.Diags[0].Code != frontend.SB030LoopShape || fe.Diags[0].Pos.String() != "budget.rb:7:3" {
		t.Fatalf("ebpf-compile's unroll-budget message no longer matches budgetMsg (bpf-mlir changed it?) — update the regular expression: %v", err)
	}
}
