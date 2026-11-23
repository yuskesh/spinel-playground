package frontend

import (
	"strings"
	"testing"
)

// TestParseTypesStrict は E025 の H5 (frontend の側): Spinel の --emit-types の JSON も文書の全体を requirements.DecodeStrictJSON の規則で先に見る
// (知らない field は今までどおり無視 — Spinel の追加に耐える)。重複の key は後勝ちで黙って読まず止まる。
func TestParseTypesStrict(t *testing.T) {
	ok := `{"types":[{"file":"a.rb","line":1,"col":0,"end_line":1,"end_col":3,"kind":"CallNode","type":"int","extra":1}]}`
	if _, err := ParseTypes([]byte(ok)); err != nil {
		t.Fatalf("want ok, got %v", err)
	}
	for _, c := range []struct{ in, rule string }{
		{strings.Replace(ok, `"type":"int"`, `"type":"str","type":"int"`, 1), "json: duplicate_key"},
		{strings.Replace(ok, `"a.rb"`, `"a.rb\u0000"`, 1), "json: nul"},
		{ok + " {}", "json: trailing_data"},
	} {
		_, err := ParseTypes([]byte(c.in))
		if err == nil || !strings.Contains(err.Error(), c.rule) {
			t.Errorf("want %q, got %v", c.rule, err)
		}
	}
}
