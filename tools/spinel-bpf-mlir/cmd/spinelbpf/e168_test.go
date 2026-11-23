package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// internalRef は公開の tree に残さない内部の参照: 計画・実験・調査の番号、review の id、agent の call-sign
// (bpf-mlir の go/internal/distribution の ref の規則と同じ — E168)。
var internalRef = regexp.MustCompile(`\b[EPR][0-9]{3,}\b|\bi[0-9]{4}\b|\b(?:viper|cougar|tiger|jaguar|anaconda|badger)-[0-9]+\b`)

// japaneseRune は日本語の文字 (bpf-mlir の japaneseCandidate と同じ Unicode の範囲)。
func japaneseRune(r rune) bool {
	switch {
	case r >= 0x3000 && r <= 0x303f, r >= 0x3040 && r <= 0x309f, r >= 0x30a0 && r <= 0x30ff, r >= 0x3190 && r <= 0x319f,
		r >= 0x31f0 && r <= 0x31ff, r >= 0x3200 && r <= 0x32ff, r >= 0x3400 && r <= 0x4dbf, r >= 0x4e00 && r <= 0x9fff,
		r >= 0xf900 && r <= 0xfaff, r >= 0xff00 && r <= 0xffef, r >= 0x20000 && r <= 0x3134f:
		return true
	}
	return false
}

// scanGoStringLiterals は dirs (root からの相対) の非 test の Go の file (`_test.go` と testdata を除く) の文字列の literal を go/parser で読み、
// 内部の参照か日本語を含む literal を `file:行: 理由: literal` で返す。comment は見ない。
func scanGoStringLiterals(root string, dirs ...string) ([]string, error) {
	var hits []string
	for _, dir := range dirs {
		err := filepath.WalkDir(filepath.Join(root, dir), func(p string, d os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				if d.Name() == "testdata" {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
				return nil
			}
			fs := token.NewFileSet()
			f, err := parser.ParseFile(fs, p, nil, parser.SkipObjectResolution)
			if err != nil {
				return err
			}
			rel, _ := filepath.Rel(root, p)
			var bad error
			ast.Inspect(f, func(x ast.Node) bool {
				b, ok := x.(*ast.BasicLit)
				if !ok || b.Kind != token.STRING || bad != nil {
					return true
				}
				// 復号した値を見る (escape の \x45123・日 等も当たる)。診断には元の表記を出す
				s, err := strconv.Unquote(b.Value)
				if err != nil {
					bad = fmt.Errorf("%s:%d: cannot unquote a string literal: %v", rel, fs.Position(b.Pos()).Line, err)
					return false
				}
				var why []string
				if m := internalRef.FindAllString(s, -1); m != nil {
					why = append(why, "internal reference "+strings.Join(m, ","))
				}
				if strings.IndexFunc(s, japaneseRune) >= 0 {
					why = append(why, "Japanese text")
				}
				if why != nil {
					v := b.Value
					if len(v) > 120 {
						v = v[:120] + "…"
					}
					hits = append(hits, fmt.Sprintf("%s:%d: %s: %s", rel, fs.Position(b.Pos()).Line, strings.Join(why, "; "), v))
				}
				return true
			})
			return bad
		})
		if err != nil {
			return nil, err
		}
	}
	sort.Strings(hits)
	return hits, nil
}

// TestNoInternalRefsInGoStrings は E168 の H1: 公開に含まれる Go (cmd・internal の非 test) の文字列の literal に内部の参照と日本語が 0
// (診断の文・生成する code — 公開の利用者が辿れない番号を残さない、bpf-mlir E703 の公開の閉包の規則と同じ)。鍵の skip の外 (毎回走る)。
func TestNoInternalRefsInGoStrings(t *testing.T) {
	hits, err := scanGoStringLiterals(repoRoot(), "cmd", "internal")
	if err != nil {
		t.Fatal(err)
	}
	for _, h := range hits {
		t.Error(h)
	}
	if len(hits) > 0 {
		t.Errorf("%d string literals carry internal references or Japanese text — reword them (state the limit itself), do not add an exception", len(hits))
	}
}

// TestNoInternalRefsInGoStringsNegative は E168 の H1 の負の対照: 一時の tree の Go の source の literal の 4 つ (番号・call-sign・review の id・日本語) を
// 名指しし、同じ文字列を comment・test の file・testdata に置いたものは数えない。
func TestNoInternalRefsInGoStringsNegative(t *testing.T) {
	root := t.TempDir()
	write := func(rel, src string) {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(src), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// The planted call-sign is built at run time so that this source carries
	// none: the published tree is scanned for call-signs, and this test must
	// still plant one for the detector to find.
	cs := "viper" + "-12"
	planted := "package x\n\n// comment: E123 " + cs + " i3188 日本語\nvar (\n\ta = \"limit (E123)\"\n\tb = `asked by " + cs + "`\n\tc = \"see i3188\"\n\td = \"日本語の文\"\n\te = \"clean: SB030 R10 E2BIG\"\n)\n" +
		// the same four written with escapes (the bpf-mlir reviewer's review i3192): E123 with a hex escape, the Japanese with Unicode escapes, the call-sign with its first letter as a hex escape, i3188 with a digit as a Unicode escape
		"var (\n\tf = \"limit (\\x45123)\"\n\tg = \"\\u65e5\\u672c\\u8a9e\"\n\th = \"asked by \\x76" + cs[1:] + "\"\n\ti = \"see i\\u0033188\"\n)\n"
	write("internal/x/x.go", planted)
	write("internal/x/x_test.go", planted)
	write("internal/x/testdata/y.go", planted)
	hits, err := scanGoStringLiterals(root, "internal")
	if err != nil {
		t.Fatal(err)
	}
	for _, h := range hits {
		t.Log(h)
	}
	want := []string{"internal/x/x.go:5: internal reference E123", "internal/x/x.go:6: internal reference " + cs, "internal/x/x.go:7: internal reference i3188", "internal/x/x.go:8: Japanese text",
		"internal/x/x.go:12: internal reference E123", "internal/x/x.go:13: Japanese text", "internal/x/x.go:14: internal reference " + cs, "internal/x/x.go:15: internal reference i3188"}
	sort.Strings(want) // hits は文字列の順 (x.go:12 は x.go:5 の前)
	if len(hits) != len(want) {
		t.Fatalf("want %d hits, got %d", len(want), len(hits))
	}
	for i, w := range want {
		if !strings.HasPrefix(hits[i], w+":") {
			t.Errorf("hit %d: want prefix %q, got %q", i, w, hits[i])
		}
	}
}
