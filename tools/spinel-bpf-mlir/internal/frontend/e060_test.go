package frontend

import (
	"os"
	"path/filepath"
	"testing"
)

// TestLoopNoSplice は E060 の H5: 受ける形 (times / each) の正の例は Spinel の builtins を継ぎ込まない (FILE が 1 つ)。
// each_with_index は継ぎ込み、E056 の補正の後で SB030 の位置が利用者の file の行と列に合う (位置は TestNegative の want)。
func TestLoopNoSplice(t *testing.T) {
	sp := testSpinel(t)
	for _, c := range []struct {
		name    string
		neg     bool
		spliced bool
	}{
		{"loop_times", false, false}, {"loop_bound", false, false}, {"loop_break_next", false, false}, {"loop_nested", false, false}, {"loop_map", false, false},
		{"loop_each_with_index", true, true},
	} {
		dir := "pos"
		if c.neg {
			dir = "neg"
		}
		b, err := os.ReadFile(filepath.Join("testdata", dir, c.name+".rb"))
		if err != nil {
			t.Fatal(err)
		}
		an, _, err := sp.Analyze(t.TempDir(), c.name+".rb", string(b))
		if err != nil {
			t.Fatal(err)
		}
		if got := spliced(an.AST); got != c.spliced {
			t.Errorf("%s: spliced = %v, want %v (files %v)", c.name, got, c.spliced, an.AST.Files)
		}
	}
}
