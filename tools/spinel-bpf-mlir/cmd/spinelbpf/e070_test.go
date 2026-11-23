package main

import (
	"regexp"
	"strings"
	"testing"
)

// E070 の試験: 条件の区間の狭め (P017) — 正の例の .mlir の形 (添字・loop の N と clamp の有無・局所どうし)。

// TestNarrowShapes は E070 の H1: narrow_basic の ref.index 2 つ、`if k > 0 && k <= 16` の腕の loop は N 16 で clamp が無い、局所どうしの loop は N 14。
func TestNarrowShapes(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	d := buildPos(t, "narrow_basic", "")
	m := readIn(t, d, "narrow_basic.mlir")
	if n := strings.Count(m, `ebpf.ref.index`); n != 2 {
		t.Errorf("%d ebpf.ref.index, want 2", n)
	}
	for _, w := range []string{"ebpf.loop 16 unroll bound(", "ebpf.loop 14 unroll bound("} {
		if !strings.Contains(m, w) {
			t.Errorf("no %q", w)
		}
	}
	if n := len(clampIf.FindAllString(m, -1)); n != 0 {
		t.Errorf("%d clamp ebpf.if before a bound — the narrowed lower ends are ≥ 0", n)
	}
	if regexp.MustCompile(`"hist\[`).MatchString(m) {
		t.Errorf("a constant index path — the narrowed index should be a variable ref.index")
	}
	if w := readIn(t, d, "narrow_basic.compile_warnings.txt"); w != "" {
		t.Errorf("compile warnings:\n%s", w)
	}
}
