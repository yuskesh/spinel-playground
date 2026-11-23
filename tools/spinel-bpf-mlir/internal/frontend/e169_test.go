package frontend

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// codeRow は公開の docs/release.md の reason code の表の行 (`| SBnnn | Name | 意味 |`)。
var codeRow = regexp.MustCompile(`^\|\s*(SB[0-9]{3})\s*\|\s*([A-Za-z]+)\s*\|`)

// checkCodeTable は表の行の集合と codeNames の番号・名前の集合のずれを返す (足りない・余計・名前の違い・同じ番号の 2 行)。
func checkCodeTable(text string, names map[Code]string) []string {
	var bad []string
	seen := map[string]string{}
	for i, line := range strings.Split(text, "\n") {
		m := codeRow.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		code, name := m[1], m[2]
		if _, dup := seen[code]; dup {
			bad = append(bad, "line "+strconv.Itoa(i+1)+": "+code+" appears twice")
			continue
		}
		seen[code] = name
		want, ok := names[Code(code)]
		switch {
		case !ok:
			bad = append(bad, "line "+strconv.Itoa(i+1)+": "+code+" is not a reason code of the frontend")
		case want != name:
			bad = append(bad, "line "+strconv.Itoa(i+1)+": "+code+" is named "+name+", the frontend names it "+want)
		}
	}
	var missing []string
	for c := range names {
		if _, ok := seen[string(c)]; !ok {
			missing = append(missing, string(c))
		}
	}
	sort.Strings(missing)
	for _, c := range missing {
		bad = append(bad, c+" ("+names[Code(c)]+") is missing from the table")
	}
	return bad
}

// TestPublicReleaseCodeTable は公開の docs の template (distribution/templates/docs/release.md) の reason code の表が
// frontend の code の表 (codeNames) と番号・名前で完全に一致すること (E169 — 手で写した表が古くならない)。
func TestPublicReleaseCodeTable(t *testing.T) {
	p := filepath.Join("..", "..", "distribution", "templates", "docs", "release.md")
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	for _, b := range checkCodeTable(string(data), codeNames) {
		t.Errorf("%s: %s", p, b)
	}
}

// TestPublicReleaseCodeTableNegative は照合の負の対照: 行を 1 つ消す・名前を変える・知らない番号・同じ番号の 2 行を、それぞれ名指す。
func TestPublicReleaseCodeTableNegative(t *testing.T) {
	names := map[Code]string{"SB000": "Spinel", "SB001": "UnsupportedConstruct", "SB002": "UnsupportedCall"}
	good := "| code | name | meaning |\n|---|---|---|\n| SB000 | Spinel | a |\n| SB001 | UnsupportedConstruct | b |\n| SB002 | UnsupportedCall | c |\n"
	if bad := checkCodeTable(good, names); len(bad) != 0 {
		t.Fatalf("the good table: %v", bad)
	}
	cases := []struct{ name, text, want string }{
		{"missing", strings.Replace(good, "| SB002 | UnsupportedCall | c |\n", "", 1), "SB002 (UnsupportedCall) is missing"},
		{"renamed", strings.Replace(good, "UnsupportedCall", "UnsupportedCalls", 1), "SB002 is named UnsupportedCalls, the frontend names it UnsupportedCall"},
		{"unknown", good + "| SB099 | Extra | d |\n", "SB099 is not a reason code"},
		{"twice", good + "| SB001 | UnsupportedConstruct | b |\n", "SB001 appears twice"},
	}
	for _, c := range cases {
		bad := checkCodeTable(c.text, names)
		t.Logf("%s: %v", c.name, bad)
		if len(bad) != 1 || !strings.Contains(bad[0], c.want) {
			t.Errorf("%s: want one finding containing %q, got %v", c.name, c.want, bad)
		}
	}
}
