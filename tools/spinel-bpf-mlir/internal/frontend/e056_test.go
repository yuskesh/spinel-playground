package frontend

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E056 の試験: Spinel の builtins の継ぎ込みの行のずれ k の測りと補正 (upstream_suspects S11)。

// analyzeRun は source の plain の Spinel の run と、root の typing の注入の run (analyze と同じ形) を返す。
func analyzeRuns(t *testing.T, path, root string) (base, text, inj string, plain, typing *Analysis) {
	t.Helper()
	sp := testSpinel(t)
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text = string(b)
	base = filepath.Base(path)
	inj = text + "if false\n  " + root + "(BPF::XdpMd.new)\nend\n"
	d := t.TempDir()
	plain, _, err = sp.Analyze(filepath.Join(d, "plain"), base, text)
	if err != nil {
		t.Fatal(err)
	}
	typing, _, err = sp.Analyze(filepath.Join(d, "typing"), base, inj)
	if err != nil {
		t.Fatal(err)
	}
	return
}

// TestSpliceShift は E056 の H1・H3・H8: 継ぎ込みの在る 2 つの source で plain と typing の k が同じで (count の最小の例 2・ringworker の count の形 2)、
// 補正の後に typing の FILE 0 の全ての node の型の引きの数が補正の前と同じ (AST と record を同じ k で戻した)。
func TestSpliceShift(t *testing.T) {
	for _, c := range []struct {
		path, root string
		want       int
	}{
		{filepath.Join("testdata", "pos", "enum_name_count.rb"), "prog", 2},
		{filepath.Join("..", "..", "docs", "experiments", "results", "E056", "ringworker_count.rb"), "ringworker", 2}, // H3 の予測は 1 (E055 の最初の形の読み) — 測った値は 2 (E056 の結果)
	} {
		base, text, inj, plain, typing := analyzeRuns(t, c.path, c.root)
		if !spliced(plain.AST) || !spliced(typing.AST) {
			t.Fatalf("%s: want a builtins splice in both runs", c.path)
		}
		fid := userFileID(typing.AST, base)
		before := map[int][2]int{}
		for id, n := range typing.AST.Nodes {
			if n != nil && n.FileID == fid {
				_, a := typing.Types.TypeOf(typing.AST, n)
				_, b := typing.Types.CodegenOf(typing.AST, n)
				before[id] = [2]int{a, b}
			}
		}
		kp, okp := alignSplice(plain, base, text)
		kt, okt := alignSplice(typing, base, inj)
		t.Logf("%s: plain k=%d (%v), typing k=%d (%v)", filepath.Base(c.path), kp, okp, kt, okt)
		if !okp || !okt || kp != c.want || kt != c.want {
			t.Errorf("%s: want k=%d in both runs", c.path, c.want)
		}
		for id, n := range typing.AST.Nodes {
			if n == nil || n.FileID != fid {
				continue
			}
			_, a := typing.Types.TypeOf(typing.AST, n)
			_, b := typing.Types.CodegenOf(typing.AST, n)
			if [2]int{a, b} != before[id] {
				t.Errorf("%s: node %d (%s line %d) type lookups changed %v → %v", c.path, id, n.Type, n.Line, before[id], [2]int{a, b})
			}
		}
		// H3: ringworker の count の形は補正で診断 0 (E055 の最初の形の SB014 / SB024 の偽の誤りが出ない)
		res, err := Analyze(testSpinel(t), t.TempDir(), c.path, text)
		if err != nil || res.Diags.Blocking() {
			t.Errorf("%s: want no blocking diagnostic after the correction: %v %v", c.path, err, res.Diags)
		}
	}
}

// TestSpliceMeasureSynthetic は E056 の H4・H6: 合成の AST — 上限を超えるずれ (+5)・照らしの node が無い・2 つの k が合う — は測れない (SB000 の側)。
func TestSpliceMeasureSynthetic(t *testing.T) {
	lines := []string{"require \"bpf\"", "", "Counts = 1", "Other = 2"}
	mk := func(ns ...*Node) *AST {
		a := &AST{Nodes: map[int]*Node{}, Files: map[int]string{0: "x.rb"}}
		for i, n := range ns {
			a.Nodes[i] = n
		}
		return a
	}
	cw := func(name string, line int) *Node {
		return &Node{Type: "ConstantWriteNode", Str: map[string]string{"name": name}, Line: line, Col: 0}
	}
	if k, ok := measureShift(mk(cw("Counts", 3+2), cw("Other", 4+2)), 0, lines); !ok || k != 2 {
		t.Errorf("a +2 shift should measure k=2, got %d %v", k, ok)
	}
	if _, ok := measureShift(mk(cw("Counts", 3+5), cw("Other", 4+5)), 0, lines); ok {
		t.Errorf("a +5 shift (over the limit %d) must not be measured", spliceMaxShift)
	}
	if _, ok := measureShift(mk(), 0, lines); ok {
		t.Errorf("no anchor must not be measured")
	}
	same := []string{"A = 1", "A = 1", "A = 1"}
	if _, ok := measureShift(mk(cw("A", 3)), 0, same); ok {
		t.Errorf("an anchor that fits two shifts must not be measured")
	}
}

// TestLibraryNoBuiltinsSplice は E058 の追加の検査: 利用者の program に入る library (ruby/lib/bpf.rb・spinelbpf.rb) が Spinel の builtins の継ぎ込み
// (S11 — Enumerable・Integer・Comparable の method の名前) を起こさない。起こすと全ての program の行がずれ、E056 の補正に頼る形になる
// (E058 で library の method `count` と局所変数 `digits` が起こし、eBPF の側の型の試験が落ちた)。
func TestLibraryNoBuiltinsSplice(t *testing.T) {
	sp := testSpinel(t)
	path := filepath.Join("..", "..", "examples", "xdpcount", "xdpcount.rb")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	an, _, err := sp.Analyze(t.TempDir(), "xdpcount.rb", string(b))
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range an.AST.Files {
		if strings.Contains(p, "/builtins/") {
			t.Errorf("the library makes Spinel splice %s into every program (upstream_suspects S11) — rename the method / variable that names a builtin method", p)
		}
	}
}
