package frontend

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"testing"
)

// TestMapKindPredicates は E121 の入口の検査: IsArray を明示に (前は !IsHash — 新しい kind が黙って array の key の lowering になった)。
func TestMapKindPredicates(t *testing.T) {
	for _, c := range []struct {
		kind             string
		array, hash, lpm bool
		flags            uint64
	}{
		{"", true, false, false, 0},
		{"percpu_array", true, false, false, 0},
		{"hash", false, true, false, 0},
		{"lru_hash", false, true, false, 0},
		{"percpu_hash", false, true, false, 0},
		{"lpm_trie", false, false, true, 1},
	} {
		m := &MapDecl{Kind: c.kind}
		if m.IsArray() != c.array || m.IsHash() != c.hash || m.IsLpm() != c.lpm || m.Flags() != c.flags {
			t.Errorf("kind %q: IsArray %v IsHash %v IsLpm %v Flags %d, want %v %v %v %d", c.kind, m.IsArray(), m.IsHash(), m.IsLpm(), m.Flags(), c.array, c.hash, c.lpm, c.flags)
		}
	}
}

// TestLpmOutputs は E121 H2: lpm_basic の 2 回の生成が byte 同じ、schema の lpm_trie の map は flags 1 と library の key の record_ref、maps.json は
// lpm_trie の宣言だけが flags 1 を持ち (他の宣言は flags の key を持たない — 既存の文書と byte 同じ)、key の record の member は prefixlen u32 @0・addr [4]u8 @4。
func TestLpmOutputs(t *testing.T) {
	sp := testSpinel(t)
	f := filepath.Join("testdata", "pos", "lpm_basic.rb")
	a, err := Generate(sp, t.TempDir(), f)
	if err != nil {
		t.Fatal(err)
	}
	b, err := Generate(sp, t.TempDir(), f)
	if err != nil {
		t.Fatal(err)
	}
	if a.MLIR != b.MLIR || !bytes.Equal(a.Schema, b.Schema) || !bytes.Equal(a.Maps, b.Maps) {
		t.Errorf("two generations differ")
	}
	var sc struct {
		Core struct {
			Maps []struct {
				Symbol string          `json:"symbol"`
				Kind   string          `json:"kind"`
				Key    json.RawMessage `json:"key"`
				Flags  int             `json:"flags"`
			} `json:"maps"`
		} `json:"core"`
	}
	if err := json.Unmarshal(a.Schema, &sc); err != nil {
		t.Fatal(err)
	}
	lpms := 0
	for _, m := range sc.Core.Maps {
		switch m.Kind {
		case "lpm_trie":
			lpms++
			if m.Flags != 1 || !bytes.Contains(m.Key, []byte(`"record_ref"`)) || !bytes.Contains(m.Key, []byte(`"spinelbpf_lpm_key4"`)) {
				t.Errorf("schema map %s: flags %d key %s, want flags 1 and the record_ref spinelbpf_lpm_key4", m.Symbol, m.Flags, m.Key)
			}
		default:
			if m.Flags != 0 {
				t.Errorf("schema map %s (%s): flags %d, want 0", m.Symbol, m.Kind, m.Flags)
			}
		}
	}
	if lpms != 2 {
		t.Errorf("schema has %d lpm_trie maps, want 2", lpms)
	}
	var md struct {
		Records map[string]struct {
			Size    int `json:"size"`
			Members []struct {
				Name   string `json:"name"`
				Offset int    `json:"offset"`
				Type   string `json:"type"`
			} `json:"members"`
		} `json:"records"`
		Maps []map[string]any `json:"maps"`
	}
	if err := json.Unmarshal(a.Maps, &md); err != nil {
		t.Fatal(err)
	}
	for _, m := range md.Maps {
		_, has := m["flags"]
		if lpm := m["kind"] == "lpm_trie"; lpm != has || (has && m["flags"] != 1.0) {
			t.Errorf("maps.json %v: flags %v (present %v)", m["name"], m["flags"], has)
		}
	}
	k, ok := md.Records["spinelbpf_lpm_key4"]
	if !ok || k.Size != 8 || len(k.Members) != 2 || k.Members[0].Name != "prefixlen" || k.Members[0].Offset != 0 || k.Members[0].Type != "u32" || k.Members[1].Name != "addr" || k.Members[1].Offset != 4 || k.Members[1].Type != "[4]u8" {
		t.Errorf("maps.json key record = %+v (present %v)", k, ok)
	}
}
