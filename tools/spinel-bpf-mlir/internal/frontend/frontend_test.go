package frontend

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

var wantLine = regexp.MustCompile(`(?m)^# want: (SB\d{3}) (\d+):(\d+)$`)

// TestNegative は testdata/neg の各 file が、末尾の `# want: SBnnn L:C` の判定で止まることを確かめる (P001 §4 E002・E002 の H5)。
// 意図した理由で止まったかを見る: 全ての want が在り、かつ止める判定の code が全て want の code のどれか (違う code が混じれば失敗)。
func TestNegative(t *testing.T) {
	sp := testSpinel(t)
	files, _ := filepath.Glob(filepath.Join("testdata", "neg", "*.rb"))
	if len(files) < 30 {
		t.Fatalf("expected the negative corpus, found %d files", len(files))
	}
	for _, f := range files {
		f := f
		t.Run(strings.TrimSuffix(filepath.Base(f), ".rb"), func(t *testing.T) { checkNegative(t, sp, f) })
	}
}

// checkNegative は 1 つの負の例 (末尾の `# want: SBnnn L:C`) の検査 (TestNegative と E080 の TestUprobeNegative が共有)。
func checkNegative(t *testing.T, sp Spinel, f string) {
	text, err := os.ReadFile(f)
	if err != nil {
		t.Fatal(err)
	}
	wants := wantLine.FindAllStringSubmatch(string(text), -1)
	if len(wants) == 0 {
		t.Fatalf("%s has no `# want:` line", f)
	}
	res, err := Analyze(sp, t.TempDir(), f, string(text))
	if err != nil {
		t.Fatalf("analyze: %v", err)
	}
	base := filepath.Base(f)
	wantCodes := map[Code]bool{}
	for _, w := range wants {
		wantCodes[Code(w[1])] = true
		found := false
		for _, d := range res.Diags {
			if string(d.Code) == w[1] && fmt.Sprintf("%d:%d", d.Pos.Line, d.Pos.Col) == w[2]+":"+w[3] && (d.Pos.File == base || d.Pos.Line == 0) && (d.Verdict == Rejected || d.Verdict == Unknown) {
				found = true
			}
		}
		if !found {
			t.Errorf("want %s at %s:%s, got:\n%s", w[1], w[2], w[3], (&Error{Diags: res.Diags}).Error())
		}
	}
	for _, d := range res.Diags {
		if (d.Verdict == Rejected || d.Verdict == Unknown) && !wantCodes[d.Code] {
			t.Errorf("stopped for an unintended reason: %s", d)
		}
	}
	// 止める診断はちょうど want の行の数 (E026 のレビューの P3 — 重ねて出る診断を落とす。理由の優先順位の表 (result.go) の試験での固定)
	blocking := 0
	for _, d := range res.Diags {
		if d.Verdict == Rejected || d.Verdict == Unknown {
			blocking++
		}
	}
	if blocking != len(wants) {
		t.Errorf("want exactly %d stopping diagnostic(s), got %d:\n%s", len(wants), blocking, (&Error{Diags: res.Diags}).Error())
	}
	if len(res.Programs) != 0 {
		t.Errorf("a refused program still produced %d programs", len(res.Programs))
	}
}

// TestPositive は testdata/pos の各 file が生成でき、ebpf-opt・ebpf-compile・ebpf-schema-check を通ることを確かめる。
func TestPositive(t *testing.T) {
	sp := testSpinel(t)
	files, _ := filepath.Glob(filepath.Join("testdata", "pos", "*.rb"))
	if len(files) == 0 {
		t.Fatal("no positive cases")
	}
	for _, f := range files {
		f := f
		t.Run(strings.TrimSuffix(filepath.Base(f), ".rb"), func(t *testing.T) {
			out, err := Generate(sp, t.TempDir(), f)
			if err != nil {
				t.Fatalf("generate: %v", err)
			}
			compileAll(t, out)
		})
	}
}

// compileAll は生成物を bpf-mlir の道具に通す。
func compileAll(t *testing.T, out *Output) []byte {
	t.Helper()
	bin := filepath.Join(repoRoot(t), "build", "bpf-mlir", "bin")
	dir := t.TempDir()
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.WriteFile(filepath.Join(dir, "x.mlir"), []byte(out.MLIR), 0o644))
	must(os.WriteFile(filepath.Join(dir, "x.schema.json"), out.Schema, 0o644))
	for _, c := range [][]string{
		{"ebpf-schema-check", "x.schema.json"},
		{"ebpf-opt", "x.mlir", "-o", "/dev/null"},
		{"ebpf-compile", "x.mlir", "--schema", "x.schema.json", "-o", "x.bpf.o"},
	} {
		cmd := exec.Command(filepath.Join(bin, c[0]), c[1:]...)
		cmd.Dir = dir
		if o, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v: %v\n%s\n--- mlir\n%s", c, err, o, out.MLIR)
		}
	}
	elf, err := os.ReadFile(filepath.Join(dir, "x.bpf.o"))
	must(err)
	return elf
}

// TestGoldenExample は examples/xdpcount の commit した生成物が今の frontend の出力と byte で一致することを確かめる
// (生成物の再現 — 生成し直していない commit を止める)。
func TestGoldenExample(t *testing.T) {
	root := repoRoot(t)
	dir := filepath.Join(root, "examples", "xdpcount")
	out, err := Generate(testSpinel(t), t.TempDir(), filepath.Join(dir, "xdpcount.rb"))
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	for name, got := range map[string][]byte{
		"xdpcount.mlir": []byte(out.MLIR), "xdpcount.schema.json": out.Schema, "xdpcount.maps.json": out.Maps, "xdpcount.domain.json": out.Domain,
	} {
		want, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, want) {
			t.Errorf("%s differs from the frontend's output (run spinelbpf build examples/xdpcount/xdpcount.rb)\n--- got\n%s", name, got)
		}
	}
}

// TestGenerateTwice は同じ source から 2 回の生成が byte で同じことを確かめる (E002 の H3 — frontend の段)。
func TestGenerateTwice(t *testing.T) {
	src := filepath.Join(repoRoot(t), "examples", "xdpcount", "xdpcount.rb")
	a, err := Generate(testSpinel(t), t.TempDir(), src)
	if err != nil {
		t.Fatal(err)
	}
	b, err := Generate(testSpinel(t), t.TempDir(), src)
	if err != nil {
		t.Fatal(err)
	}
	if a.MLIR != b.MLIR || !bytes.Equal(a.Schema, b.Schema) || !bytes.Equal(a.Maps, b.Maps) || !bytes.Equal(a.Domain, b.Domain) {
		t.Fatal("two generations from the same source differ")
	}
}

// TestInjectionWrongClass は P001 §3.3 (ii) の負の対照: 注入の引数を String にすると SB010 で止まる。
func TestInjectionWrongClass(t *testing.T) {
	src := filepath.Join(repoRoot(t), "examples", "xdpcount", "xdpcount.rb")
	text, _ := os.ReadFile(src)
	res, err := analyze(testSpinel(t), t.TempDir(), src, string(text), analyzeOpts{inject: `"not a context"`})
	if err != nil {
		t.Fatal(err)
	}
	if !hasCode(res.Diags, SB010TypingProbe, "5:16") {
		t.Fatalf("want SB010 at the context parameter (5:16), got:\n%v", (&Error{Diags: res.Diags}).Error())
	}
}

// TestInjectionComparator は P001 §3.3 (iii) の比較器の負の対照: 注入ありの types の root の外の record を 1 つ変えると SB010。
func TestInjectionComparator(t *testing.T) {
	src := filepath.Join(repoRoot(t), "examples", "xdpcount", "xdpcount.rb")
	text, _ := os.ReadFile(src)
	res, err := analyze(testSpinel(t), t.TempDir(), src, string(text), analyzeOpts{mutateTyping: func(ty *Types) {
		for i, r := range ty.Types {
			if r.File == "xdpcount.rb" && r.Kind == "IntegerNode" && r.Line == 6 && r.Col == 20 {
				ty.Types[i].RBS = "Float"
			}
		}
	}})
	if err != nil {
		t.Fatal(err)
	}
	if !hasCode(res.Diags, SB010TypingProbe, "6:21") {
		t.Fatalf("want SB010 at 6:21, got:\n%v", (&Error{Diags: res.Diags}).Error())
	}
}

// TestDynamicDispatch は SB004 (P001 の部分集合では source から届かない — receiver が map の定数に限られ Spinel は direct にする):
// codegen の record を switch に変えると止まる。
func TestDynamicDispatch(t *testing.T) {
	src := filepath.Join(repoRoot(t), "examples", "xdpcount", "xdpcount.rb")
	text, _ := os.ReadFile(src)
	res, err := analyze(testSpinel(t), t.TempDir(), src, string(text), analyzeOpts{mutateTyping: func(ty *Types) {
		for i, r := range ty.Codegen {
			if r.File == "xdpcount.rb" && r.Name == "atomic_add" {
				ty.Codegen[i].Dispatch, ty.Codegen[i].Callee, ty.Codegen[i].Candidates = "switch", "", []string{"ArrayMap#atomic_add", "Other#atomic_add"}
			}
		}
	}})
	if err != nil {
		t.Fatal(err)
	}
	if !hasCode(res.Diags, SB004UnknownEdge, "6:3") {
		t.Fatalf("want SB004 at 6:3, got:\n%v", (&Error{Diags: res.Diags}).Error())
	}
}

// TestAmbiguousType は SB015: 1 つの node に 2 つの型の record (特殊化) を与えると止まる。
func TestAmbiguousType(t *testing.T) {
	src := filepath.Join(repoRoot(t), "examples", "xdpcount", "xdpcount.rb")
	text, _ := os.ReadFile(src)
	res, err := analyze(testSpinel(t), t.TempDir(), src, string(text), analyzeOpts{mutateTyping: func(ty *Types) {
		for _, r := range ty.Types {
			if r.File == "xdpcount.rb" && r.Kind == "CallNode" && r.Name == "lookup" {
				r.RBS = "Integer"
				ty.Types = append(ty.Types, r)
				return
			}
		}
	}})
	if err != nil {
		t.Fatal(err)
	}
	if !hasCode(res.Diags, SB015AmbiguousType, "7:7") {
		t.Fatalf("want SB015 at 7:7, got:\n%v", (&Error{Diags: res.Diags}).Error())
	}
}

func hasCode(ds Diags, c Code, at string) bool {
	for _, d := range ds {
		if d.Code == c && fmt.Sprintf("%d:%d", d.Pos.Line, d.Pos.Col) == at {
			return true
		}
	}
	return false
}

// TestVerifyWorld は許す op の集合が bpf-mlir の ① の部分集合で、生成の op が許す集合に入り、集合の外の op で止まることを確かめる。
func TestVerifyWorld(t *testing.T) {
	ref, err := ReferenceOps(filepath.Join(repoRoot(t), "third_party", "bpf-mlir", "docs", "reference", "ebpf_ops.md"))
	if err != nil {
		t.Fatal(err)
	}
	for _, op := range AllowedOps() {
		if strings.HasPrefix(op, "ebpf.") && !ref[op] {
			t.Errorf("allowed op %s is not a stage ① op of bpf-mlir", op)
		}
	}
	golden, err := os.ReadFile(filepath.Join(repoRoot(t), "examples", "xdpcount", "xdpcount.mlir"))
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifyWorld(string(golden)); err != nil {
		t.Fatal(err)
	}
	bad := strings.Replace(string(golden), "ebpf.map.update", "ebpf.map.delete", 1)
	if err := VerifyWorld(bad); err == nil {
		t.Fatal("verify-bpf-world accepted ebpf.map.delete (outside the allowed set)")
	}
}

// TestSameOpsAsMojo は E002 の H4: §1 の例の .mlir の op と型の並びが mojo-bpf-mlir の同じ例 (testdata/mojo_xdpcount.mlir —
// mojo-bpf-mlir examples/xdpcount/xdpcount.mlir の写し) と同じ (loc・SSA の名前・program の名前を除く)。
func TestSameOpsAsMojo(t *testing.T) {
	norm := func(s string) string {
		s = regexp.MustCompile(` loc\([^)]*\)`).ReplaceAllString(s, "")
		s = regexp.MustCompile(`%[a-z]+\d*`).ReplaceAllString(s, "%_")
		s = regexp.MustCompile(`@\w+`).ReplaceAllString(s, "@_")
		var out []string
		for _, l := range strings.Split(s, "\n") {
			l = strings.TrimSpace(l)
			if l != "" && !strings.HasPrefix(l, "//") {
				out = append(out, l)
			}
		}
		return strings.Join(out, "\n")
	}
	ours, _ := os.ReadFile(filepath.Join(repoRoot(t), "examples", "xdpcount", "xdpcount.mlir"))
	mojo, err := os.ReadFile(filepath.Join("testdata", "mojo_xdpcount.mlir"))
	if err != nil {
		t.Fatal(err)
	}
	if norm(string(ours)) != norm(string(mojo)) {
		t.Fatalf("op sequence differs from mojo-bpf-mlir's xdpcount\n--- ours\n%s\n--- mojo\n%s", norm(string(ours)), norm(string(mojo)))
	}
}

// TestCodesNamed は全ての reason code に名前があることを確かめる。
func TestCodesNamed(t *testing.T) {
	var codes []string
	for c := range codeNames {
		codes = append(codes, string(c))
	}
	sort.Strings(codes)
	if len(codes) != 36 { // P015 E060: SB030、P016 E066: SB031、P020 E080: SB032、P021 E086: SB033、P023 E092: SB034・SB035
		t.Fatalf("codes: %v", codes)
	}
}

// TestComparatorDependentRule は E002 のレビューの P2: 比較器 (iii) の「root の引数の読みを含む node の差は許す」規則は
// E002 の 1 回目の結果を見た後に足した (事後)。ctx を読む program (testdata/neg/ctx_use.rb) で、規則なしの比較器の不一致の一覧を記録し
// (規則が許した差)、規則ありでは 0 になること、そして規則が広すぎないこと (ctx の読みを含まない node の差は今も SB010) を確かめる。
func TestComparatorDependentRule(t *testing.T) {
	sp := testSpinel(t)
	src := filepath.Join("testdata", "neg", "ctx_use.rb")
	text, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	work := t.TempDir()
	res, err := analyze(sp, work, src, string(text), analyzeOpts{})
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range res.Diags {
		if d.Code == SB010TypingProbe {
			t.Fatalf("with the rule, the comparator still reports %s", d)
		}
	}
	// 同じ 2 つの解析 (work の plain / typing の types.json) を規則なしで比べる
	load := func(sub string) *Types {
		data, err := os.ReadFile(filepath.Join(work, sub, "types.json"))
		if err != nil {
			t.Fatal(err)
		}
		ty, err := ParseTypes(data)
		if err != nil {
			t.Fatal(err)
		}
		return ty
	}
	lines := strings.Count(strings.TrimSuffix(string(text), "\n"), "\n") + 1
	without := CompareTypes(load("plain"), load("typing"), "ctx_use.rb", lines, map[string]bool{"prog": true}, nil)
	var got []string
	for _, d := range without {
		got = append(got, fmt.Sprintf("%d:%d %s", d.Pos.Line, d.Pos.Col, d.Msg))
	}
	t.Logf("comparator without the dependent rule: %d mismatches\n%s", len(without), strings.Join(got, "\n"))
	if len(without) == 0 {
		t.Fatal("the rule is not needed for ctx_use.rb — the E002 record says it was")
	}
	// 負の対照: ctx を読む program でも、ctx の読みを含まない node の差は SB010 で止まる。E026 のレビューの P3 の後、他に止める理由がある program
	// (ctx_use.rb の SB001) では SB010 を落とすので、止める理由の無い pkt_ether の流れの外の node (11:12 の IntegerNode 4 — `slot = 4`) の型を変える
	src2 := filepath.Join("testdata", "pos", "pkt_ether.rb")
	text2, _ := os.ReadFile(src2)
	res2, err := analyze(sp, t.TempDir(), src2, string(text2), analyzeOpts{mutateTyping: func(ty *Types) {
		for i, r := range ty.Types {
			if r.File == "pkt_ether.rb" && r.Kind == "IntegerNode" && r.Line == 11 && r.Col == 11 {
				ty.Types[i].RBS = "Float"
			}
		}
	}})
	if err != nil {
		t.Fatal(err)
	}
	if !hasCode(res2.Diags, SB010TypingProbe, "11:12") {
		t.Fatalf("the dependent rule is too wide: a difference outside the ctx reads passed\n%v", (&Error{Diags: res2.Diags}).Error())
	}
}

// TestUnusedMapConditional は E010 の 1 回目の後の規則: 宣言だけで使われない map は Conditional の SB013 で、schema と maps.json に載らない。
func TestUnusedMapConditional(t *testing.T) {
	out, err := Generate(testSpinel(t), t.TempDir(), filepath.Join("testdata", "pos", "unused_map.rb"))
	if err != nil {
		t.Fatal(err)
	}
	if !hasCode(out.Result.Diags, SB013MapDeclShape, "4:1") {
		t.Fatalf("want a Conditional SB013 at 4:1, got %v", out.Result.Diags)
	}
	if bytes.Contains(out.Schema, []byte("Spare")) || bytes.Contains(out.Maps, []byte("Spare")) {
		t.Fatal("the unused map Spare is in the schema or maps.json")
	}
}

// TestComparatorAdditiveRule は E014 の事後の規則: root の引数から流れる値を含む node の差は、注入の無い側が型を持たない (record が無いか untyped) ときだけ許す。
// pkt_ether で、流れの中の node で注入の無い側も型を持つもの (`if w` の IfNode — Integer) の typing の型を変えると SB010 で止まる。規則なしでは流れの node の差が不一致として並ぶ。
func TestComparatorAdditiveRule(t *testing.T) {
	sp := testSpinel(t)
	src := filepath.Join("testdata", "pos", "pkt_ether.rb")
	text, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	work := t.TempDir()
	res, err := analyze(sp, work, src, string(text), analyzeOpts{})
	if err != nil || res.Diags.Blocking() {
		t.Fatalf("pkt_ether: %v %v", err, res.Diags)
	}
	load := func(sub string) *Types {
		data, err := os.ReadFile(filepath.Join(work, sub, "types.json"))
		if err != nil {
			t.Fatal(err)
		}
		ty, err := ParseTypes(data)
		if err != nil {
			t.Fatal(err)
		}
		return ty
	}
	lines := strings.Count(strings.TrimSuffix(string(text), "\n"), "\n") + 1
	without := CompareTypes(load("plain"), load("typing"), "pkt_ether.rb", lines, map[string]bool{"ether": true}, nil)
	t.Logf("comparator without the dependent rule: %d mismatches", len(without))
	if len(without) == 0 {
		t.Fatal("the dependent rule is not needed for pkt_ether.rb")
	}
	res2, err := analyze(sp, t.TempDir(), src, string(text), analyzeOpts{mutateTyping: func(ty *Types) {
		for i, r := range ty.Types {
			if r.File == "pkt_ether.rb" && r.Kind == "IfNode" && r.Line == 9 && r.Col == 2 {
				ty.Types[i].RBS = "Float"
			}
		}
	}})
	if err != nil {
		t.Fatal(err)
	}
	if !hasCode(res2.Diags, SB010TypingProbe, "9:3") {
		t.Fatalf("the additive rule is too wide: a typed node in the flow changed type and passed\n%v", (&Error{Diags: res2.Diags}).Error())
	}
}

// TestNoUncheckedPacketLoad は E014 の H2: 検査の無い ebpf.packet.load は許す op に無い (範囲外の暗黙の 0 — P004 §0)。
func TestNoUncheckedPacketLoad(t *testing.T) {
	for _, op := range AllowedOps() {
		if op == "ebpf.packet.load" || op == "ebpf.packet.store" {
			t.Fatalf("%s is in the allowed ops", op)
		}
	}
	if err := VerifyWorld("  %v0 = ebpf.packet.load %ctx[%v1] : !ebpf.ctx<\"xdp\">, i64 -> i8\n"); err == nil {
		t.Fatal("VerifyWorld accepted ebpf.packet.load")
	}
}

// TestPacketReproducible は E014 の H4: packet の正の例の .mlir と schema が 2 回の生成で byte 同じ。
func TestPacketReproducible(t *testing.T) {
	sp := testSpinel(t)
	files, _ := filepath.Glob(filepath.Join("testdata", "pos", "pkt_*.rb"))
	if len(files) < 4 {
		t.Fatalf("want the packet positives, got %v", files)
	}
	for _, f := range files {
		a, err := Generate(sp, t.TempDir(), f)
		if err != nil {
			t.Fatal(err)
		}
		b, err := Generate(sp, t.TempDir(), f)
		if err != nil {
			t.Fatal(err)
		}
		if a.MLIR != b.MLIR || !bytes.Equal(a.Schema, b.Schema) {
			t.Errorf("%s: two generations differ", f)
		}
	}
}

// TestUntypedSpellingCanary は E014 のレビューの P2: 比較器の additive の条件は Spinel の「型が無い」の綴り (RBS "untyped" と空の signature — untypedOnly) に依る。
// 既知の入力 (pkt_ether) で、注入の無い側の流れの中の node (`w = ctx.check(0, 14)` の LocalVariableWriteNode と `if w` の read) がその綴りであることを固定する。
// Spinel の版を上げて綴りが変わったら、この試験が名指しで落ちる (許しが黙って消える / 別の綴りを型として比べる前に)。
func TestUntypedSpellingCanary(t *testing.T) {
	sp := testSpinel(t)
	src := filepath.Join("testdata", "pos", "pkt_ether.rb")
	text, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	work := t.TempDir()
	if _, err := analyze(sp, work, src, string(text), analyzeOpts{}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(work, "plain", "types.json"))
	if err != nil {
		t.Fatal(err)
	}
	ty, err := ParseTypes(data)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]string{}
	for _, r := range ty.Types {
		if r.File == "pkt_ether.rb" && r.Line == 8 && r.Col == 2 && r.Kind == "LocalVariableWriteNode" {
			seen["write"] = r.Name + "|" + r.RBS + "|" + r.Signature
		}
		if r.File == "pkt_ether.rb" && r.Line == 9 && r.Col == 5 && r.Kind == "LocalVariableReadNode" {
			seen["read"] = r.Name + "|" + r.RBS + "|" + r.Signature
		}
	}
	for _, k := range []string{"write", "read"} {
		if seen[k] != "w|untyped|" || !untypedOnly([]string{seen[k]}) {
			t.Fatalf("Spinel's spelling of \"no type\" changed: the %s of `w` in pkt_ether.rb without the typing probe is %q, want \"w|untyped|\" — update untypedOnly (the comparator's additive rule, E014) for this Spinel version", k, seen[k])
		}
	}
}

// TestRecordComparator は E020 の H5 (P006 のレビューの (a) (ii)): record の型が 2 つで ctx から key と値が流れる rec_pkt で、規則なしの比較器は不一致を出し規則ありで 0、
// 流れの中で注入の無い側も型を持つ node (`if p` の IfNode — p は ctx から流れる key の lookup) の typing の型を変えると SB010 — additive の規則が p.load の流れで型を黙って広げない。
// (1 回目は rec_basic で書いた — ctx を読まない program は注入の有無で不一致 0 (record の流れの型は注入で変わらない) — TestRecordComparatorNoCtx に残した)
func TestRecordComparator(t *testing.T) {
	sp := testSpinel(t)
	src := filepath.Join("testdata", "pos", "rec_pkt.rb")
	text, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	work := t.TempDir()
	res, err := analyze(sp, work, src, string(text), analyzeOpts{})
	if err != nil || res.Diags.Blocking() {
		t.Fatalf("rec_basic: %v %v", err, res.Diags)
	}
	load := func(sub string) *Types {
		data, err := os.ReadFile(filepath.Join(work, sub, "types.json"))
		if err != nil {
			t.Fatal(err)
		}
		ty, err := ParseTypes(data)
		if err != nil {
			t.Fatal(err)
		}
		return ty
	}
	lines := strings.Count(strings.TrimSuffix(string(text), "\n"), "\n") + 1
	without := CompareTypes(load("plain"), load("typing"), "rec_pkt.rb", lines, map[string]bool{"prog": true}, nil)
	t.Logf("comparator without the dependent rule: %d mismatches", len(without))
	for _, d := range without {
		t.Logf("  %s", d)
	}
	if len(without) == 0 {
		t.Fatal("the dependent rule is not needed for rec_pkt.rb")
	}
	res2, err := analyze(sp, t.TempDir(), src, string(text), analyzeOpts{mutateTyping: func(ty *Types) {
		for i, r := range ty.Types {
			if r.File == "rec_pkt.rb" && r.Kind == "IfNode" && r.Line == 16 && r.Col == 4 {
				ty.Types[i].RBS = "Float"
			}
		}
	}})
	if err != nil {
		t.Fatal(err)
	}
	if !hasCode(res2.Diags, SB010TypingProbe, "16:5") {
		t.Fatalf("the additive rule let a typed node in the p.load flow change type\n%v", (&Error{Diags: res2.Diags}).Error())
	}
}

// TestRecordReproducible は E020 の H2: record の正の例の .mlir・schema・maps.json が 2 回の生成で byte 同じ、schema に records と record_ref。
func TestRecordReproducible(t *testing.T) {
	sp := testSpinel(t)
	files, _ := filepath.Glob(filepath.Join("testdata", "pos", "rec_*.rb"))
	if len(files) == 0 {
		t.Fatal("no record positives")
	}
	files = append(files, filepath.Join("testdata", "pos", "ring_basic.rb")) // E026: ring buffer の record (records は ringbuf の行の record)
	files = append(files, filepath.Join("testdata", "pos", "hash_basic.rb")) // E032: hash の record の key と値 (records は key の record を先に)
	files = append(files, filepath.Join("testdata", "pos", "percpu_basic.rb")) // E038: per-CPU の map
	for _, f := range files {
		a, err := Generate(sp, t.TempDir(), f)
		if err != nil {
			t.Fatal(err)
		}
		b, err := Generate(sp, t.TempDir(), f)
		if err != nil {
			t.Fatal(err)
		}
		if a.MLIR != b.MLIR || !bytes.Equal(a.Schema, b.Schema) || !bytes.Equal(a.Maps, b.Maps) {
			t.Errorf("%s: two generations differ", f)
		}
		if !(bytes.Contains(a.Schema, []byte(`"kind": "record_ref"`)) || bytes.Contains(a.Schema, []byte(`"kind": "ringbuf"`))) || !bytes.Contains(a.Maps, []byte(`"records"`)) || !bytes.Contains(a.Maps, []byte(`"value": "record:`)) {
			t.Errorf("%s: schema / maps.json lack the record parts", f)
		}
	}
}

// TestRecordComparatorNoCtx は E020 の 1 回目の観察: ctx を読まない record の program (rec_basic) は注入の有無で比較器の不一致が 0 — record の流れの型は注入で変わらない。
func TestRecordComparatorNoCtx(t *testing.T) {
	sp := testSpinel(t)
	src := filepath.Join("testdata", "pos", "rec_basic.rb")
	text, _ := os.ReadFile(src)
	work := t.TempDir()
	if _, err := analyze(sp, work, src, string(text), analyzeOpts{}); err != nil {
		t.Fatal(err)
	}
	load := func(sub string) *Types {
		data, _ := os.ReadFile(filepath.Join(work, sub, "types.json"))
		ty, err := ParseTypes(data)
		if err != nil {
			t.Fatal(err)
		}
		return ty
	}
	lines := strings.Count(strings.TrimSuffix(string(text), "\n"), "\n") + 1
	if d := CompareTypes(load("plain"), load("typing"), "rec_basic.rb", lines, map[string]bool{"prog": true}, nil); len(d) != 0 {
		t.Fatalf("want no mismatches without ctx reads, got %v", d)
	}
}

// TestLibraryKeepsEBPFTypes は E022 のレビューの P2 (gate): spinelbpf の library の公開の API を呼ぶ user 空間の側を足しても、eBPF の program の def の中の
// Spinel の推論の型 (typing の types.json の record — 位置・kind・名前・型) が変わらない。record を使う program と使わない program の両方で。
// 多相の API や splat の生成が whole-program の推論で eBPF の側の型を壊す形 (E021 / E022 — S8 系) を入口で捕まえる。
func TestLibraryKeepsEBPFTypes(t *testing.T) {
	sp := testSpinel(t)
	cases := []struct {
		name, user string
		poison     bool // 対照: 型を壊す形 — 変化が出ることを期待
	}{
		{"rec_basic", `
require "spinelbpf"
obj = SpinelBPF.load_embedded
v = obj.map_get_record(Stats, 0)
s = Stat.new(v[0], v[1], v[2], v[3], v[4])
obj.map_put_record(Stats, 1, s)
w = obj.map_get_record(Pairs, 1)
obj.map_put_record(Pairs, 0, Pair.new(w[0], w[1]))
x = obj.map_get(Out, 0)
obj.map_put(Out, 1, x)
obj.test_run_xdp("prog", 1)
obj.test_run_xdp_packet("prog", Array.new(14, 0))
puts obj.unmet.length
obj.close
`, false},
		{"lpm_basic", `
require "spinelbpf"
obj = SpinelBPF.load_embedded
obj.lpm_put(Rules, "10.0.0.0/8", 1)
puts obj.lpm_remove(Rules, "10.0.0.0/8")
puts obj.lpm_match(Rules, "10.1.2.3")
puts obj.lpm_has(Signed, "10.0.0.1")
l = obj.lpm_list(Rules)
puts l.length
puts SpinelBPF.lpm_prefix_len("10.0.0.0/8")
x = obj.map_get(Out, 0)
obj.map_put(Out, 1, x)
obj.test_run_xdp_packet("ipdeny", Array.new(64, 0))
puts obj.unmet.length
obj.close
`, false},
		{"sf_basic", `
require "spinelbpf"
obj = SpinelBPF.load_embedded
obj.attach_socket("short_only", 3)
puts obj.test_run_skb_packet("short_only", Array.new(78, 0))
puts obj.map_get(Out, 0)
puts obj.unmet.length
obj.close
`, false},
		{"cgs_basic", `
require "spinelbpf"
obj = SpinelBPF.load_embedded
l = obj.attach_cgroup("small_in", 3)
l.detach
puts obj.test_run_skb_packet("small_out", Array.new(78, 0))
puts obj.map_get(Out, 1)
puts obj.unmet.length
obj.close
`, false},
		{"nf_basic", `
require "spinelbpf"
obj = SpinelBPF.load_embedded
puts obj.test_run_netfilter("small_only", Array.new(40, 0), 2, 3)
puts obj.map_get(Out, 2)
puts obj.unmet.length
obj.close
`, false},
		{"ctxf_basic", `
require "spinelbpf"
obj = SpinelBPF.load_embedded
puts obj.test_run_xdp_packet("ifx", Array.new(64, 0))
puts obj.test_run_tc_packet("mark_in", Array.new(64, 0))
puts obj.map_get(Out, 3)
obj.close
`, false},
		{"adjh_basic", `
require "spinelbpf"
obj = SpinelBPF.load_embedded
obj.map_put(D, 0, 4)
puts obj.test_run_xdp_packet("shift", Array.new(64, 0))
puts obj.map_get(Out, 0)
obj.close
`, false},
		{"adjt_basic", `
require "spinelbpf"
obj = SpinelBPF.load_embedded
puts obj.test_run_xdp_packet("trim4", Array.new(64, 0))
puts obj.map_get(Out, 0)
obj.close
`, false},
		{"flow_basic", `
require "spinelbpf"
obj = SpinelBPF.load_embedded
r = obj.test_run_flow_dissector("flow4", Array.new(64, 0))
puts r[0]
puts r.length
l = obj.attach_netns("flow4", 3)
l.detach
obj.close
`, false},
		{"ops_int", `
require "spinelbpf"
obj = SpinelBPF.load_embedded
x = obj.map_get(In, 0)
obj.map_put(In, 1, x)
obj.test_run_xdp("prog", 1)
obj.test_run_xdp_packet("prog", Array.new(14, 0))
puts obj.unmet.length
obj.close
`, false},
		{"ring_basic", `
require "spinelbpf"
obj = SpinelBPF.load_embedded
x = obj.map_get(Drops, 0)
obj.map_put(Drops, 1, x)
obj.test_run_xdp_packet("prog", Array.new(64, 0))
r = obj.ringbuf(Events)
e = r.read_record(0)
if e.length > 0
  ev = Event.new(e[0], e[1], e[2], e[3], e[4], e[5])
  puts ev.len
end
k = obj.ringbuf(Ticks)
u = k.read_record(10)
puts u.length
k.close
r.close
puts obj.unmet.length
obj.close
`, false},
		{"hash_basic", `
require "spinelbpf"
obj = SpinelBPF.load_embedded
x = obj.map_get(Out, 0)
obj.map_put(Out, 1, x)
obj.hash_put(Counts, 7, x)
y = obj.hash_get(Counts, 7)
puts obj.hash_has(Counts, 8)
puts obj.hash_delete(Counts, 8)
puts obj.hash_keys(Counts).length
obj.hash_put(Seen, -1, 2)
puts obj.hash_get(Seen, -1)
v = obj.hash_get_record(ByPort, 443)
obj.hash_put_record(ByPort, 443, Stat.new(v[0], v[1]))
k = obj.hash_keys_rk(Flows)
if k.length > 0
  fk = FlowKey.new(k[0][0], k[0][1], k[0][2], k[0][3])
  w = obj.hash_get_record_rk(Flows, fk)
  obj.hash_put_record_rk(Flows, fk, Stat.new(w[0], w[1]))
  puts obj.hash_has_rk(Flows, fk)
  puts obj.hash_delete_rk(Flows, fk)
end
puts y
obj.test_run_xdp("prog", 1)
puts obj.unmet.length
obj.close
`, false},
		{"percpu_basic", `
require "spinelbpf"
obj = SpinelBPF.load_embedded
n = SpinelBPF.possible_cpus
a = obj.percpu_get_record(PerProto, 3)
recs = []
i = 0
while i < a.length
  recs.push(Stats.new(a[i][0], a[i][1], a[i][2], a[i][3]))
  i += 1
end
obj.percpu_put_record(PerProto, 3, recs)
h = obj.percpu_get(Hits, 0)
obj.percpu_put(Hits, 0, h)
puts SpinelBPF.sum(h)
f = obj.percpu_hash_get_rk(PerFlow, FlowKey.new(17, 0, 53, 16909060))
obj.percpu_hash_put_rk(PerFlow, FlowKey.new(17, 0, 53, 16909060), f)
k = obj.percpu_hash_keys_rk(PerFlow)
puts k.length
puts obj.percpu_hash_has_rk(PerFlow, FlowKey.new(1, 0, 1, 1))
puts obj.percpu_hash_delete_rk(PerFlow, FlowKey.new(1, 0, 1, 1))
g = obj.percpu_hash_get_record(PerPort, 53)
obj.percpu_hash_put_record(PerPort, 53, [Stats.new(g[0][0], g[0][1], g[0][2], g[0][3])])
puts obj.percpu_hash_keys(PerPort).length
puts obj.percpu_hash_has(PerPort, 1)
puts obj.percpu_hash_delete(PerPort, 1)
puts n
obj.test_run_xdp("prog", 1)
obj.close
`, false},
		// 対照 (E022 の 1 回目の形): 多相の戻り値 (Array か Integer) の値で record の Struct を作ると、eBPF の側の型が変わる — この試験が捕まえる
		{"rec_basic", `
def either(k)
  if k > 0
    return [1, 2, 3, 0, 5]
  end
  7
end
v = either(1)
s = Stat.new(v[0], v[1], v[2], v[3], v[4])
puts s.hits
`, true},
	}
	for _, c := range cases {
		src := filepath.Join("testdata", "pos", c.name+".rb")
		text, err := os.ReadFile(src)
		if err != nil {
			t.Fatal(err)
		}
		types := func(body string) (map[string]string, *Result) {
			d := t.TempDir()
			p := filepath.Join(d, c.name+".rb")
			os.WriteFile(p, []byte(body), 0o644)
			work := t.TempDir()
			res, err := analyze(sp, work, p, body, analyzeOpts{})
			if err != nil || (res.Diags.Blocking() && !c.poison) {
				t.Fatalf("%s: %v %v", c.name, err, res.Diags)
			}
			data, err := os.ReadFile(filepath.Join(work, "typing", "types.json"))
			if err != nil {
				t.Fatal(err)
			}
			ty, err := ParseTypes(data)
			if err != nil {
				t.Fatal(err)
			}
			out := map[string]string{}
			for _, r := range ty.Types {
				for _, pr := range res.Programs {
					if r.File == c.name+".rb" && r.Line >= pr.Pos.Line && r.EndLine <= pr.EndLine {
						out[fmt.Sprintf("%d:%d:%d:%d:%s", r.Line, r.Col, r.EndLine, r.EndCol, r.Kind)] += r.Name + "|" + r.RBS + ";"
					}
				}
			}
			return out, res
		}
		plain, _ := types(string(text))
		with, _ := types(string(text) + c.user)
		if len(plain) == 0 {
			t.Fatalf("%s: no typed nodes in the eBPF program", c.name)
		}
		diff := 0
		for k, v := range plain {
			if with[k] != v {
				diff++
				if c.poison {
					continue
				}
				t.Errorf("%s: the eBPF-side type at %s changed with the user-space side: %q → %q", c.name, k, v, with[k])
			}
		}
		if c.poison {
			if diff == 0 {
				t.Errorf("%s (control): the poisoning user code changed no eBPF-side type — the test would not catch it", c.name)
			}
			t.Logf("%s (control — polymorphic value into Stat.new): %d of %d eBPF-side typed nodes changed", c.name, diff, len(plain))
			continue
		}
		t.Logf("%s: %d eBPF-side typed nodes, %d changed", c.name, len(plain), diff)
	}
}
