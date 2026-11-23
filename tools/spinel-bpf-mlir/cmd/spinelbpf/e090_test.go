package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestTutorialCommands は E090: docs/tutorial.md の `sh` の block の各行 (空と注釈を除く) が scripts/tutorial-run.sh に同じ綴りの行として在る
// (頁と runner の食い違いを落とす — runner が頁の command を走らせたことの根拠)。
func TestTutorialCommands(t *testing.T) {
	parallel(t) // P018 E075
	tut, err := os.ReadFile(filepath.Join(repoRoot(), "docs", "tutorial.md"))
	if err != nil {
		t.Fatal(err)
	}
	run, err := os.ReadFile(filepath.Join(repoRoot(), "scripts", "tutorial-run.sh"))
	if err != nil {
		t.Fatal(err)
	}
	have := map[string]bool{}
	for _, l := range strings.Split(string(run), "\n") {
		have[strings.TrimSpace(l)] = true
	}
	in, n := false, 0
	for _, l := range strings.Split(string(tut), "\n") {
		switch {
		case l == "```sh":
			in = true
		case l == "```":
			in = false
		case in && strings.TrimSpace(l) != "" && !strings.HasPrefix(strings.TrimSpace(l), "#"):
			n++
			if !have[strings.TrimSpace(l)] {
				t.Errorf("the tutorial's command %q is not a line of scripts/tutorial-run.sh", l)
			}
		}
	}
	if n < 10 {
		t.Errorf("only %d tutorial commands — the sh blocks were not found", n)
	}
}
