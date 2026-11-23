package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestSchemaReadStrict は E025 の H5 (build の側): build が schema を読む 2 か所 (map の symbol の照合・record の表の照合) は、
// 文書の全体を requirements.DecodeStrictJSON の規則で先に見る — 例の schema は通り、重複の key と nul は規則の名前付きで止まる。
func TestSchemaReadStrict(t *testing.T) {
	parallel(t) // P018 E075
	b, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "lastseen", "lastseen.schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct{}
	if err := strictUnmarshal(b, &doc); err != nil {
		t.Fatalf("the committed schema should pass: %v", err)
	}
	for _, c := range []struct{ name, from, to, rule string }{
		{"dup", `"size": `, `"size": 1, "size": `, "json: duplicate_key"},
		{"nul", `"symbol": "`, `"symbol": "\u0000`, "json: nul"},
	} {
		bad := strings.Replace(string(b), c.from, c.to, 1)
		if bad == string(b) {
			t.Fatalf("%s: the rewrite did not apply", c.name)
		}
		err := checkRecordsTable([]byte(bad), "")
		t.Logf("%s: %v", c.name, err)
		if err == nil || !strings.Contains(err.Error(), c.rule) {
			t.Errorf("%s: want %q, got %v", c.name, c.rule, err)
		}
	}
}
