package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E033 の試験: user 空間の hash の API (P008 §3)。

func buildHashio(t *testing.T) (string, string) {
	t.Helper()
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e033-")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "hash", "hashio.rb"))
	src := filepath.Join(d, "hashio.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "hashio")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe, d
}

// TestHashUserAPI は E033 の H1〜H3 (host、root): 4 つの組の往復 (境界の値)・eBPF の側との行き来・NotFound・has・delete の bool・満杯の E2BIG・
// ValueRange (範囲・padding)・名前と種類の食い違いの MapMismatch・列挙 (並べ替えて比べる)。
func TestHashUserAPI(t *testing.T) {
	parallel(t) // P018 E075
	exe, _ := buildHashio(t)
	want, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "hash", "hashio.want"))
	out := feed(t, true, "", exe)
	if out != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", out, want)
	}
}

// TestHashKeyTable は E033 の H5: 埋め込みの表の record の key の行 (`M:key|K|…`) が 2 回の build で byte 同じで schema と一致し、
// key の行の offset を書き換えた表は build の検査が名指しで止める。
func TestHashKeyTable(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	_, d1 := buildHashio(t)
	_, d2 := buildHashio(t)
	a, _ := os.ReadFile(filepath.Join(d1, "hashio_embed.S"))
	b, _ := os.ReadFile(filepath.Join(d2, "hashio_embed.S"))
	if len(a) == 0 || string(a) != string(b) {
		t.Fatal("the embedding differs between two builds")
	}
	table := "C|S|size=16;frames:0:u64;delta:8:i32;_pad0:12:u32;\nD:key|K|size=8;proto:0:u8;_pad0:1:u8;port:2:u16;addr:4:u32;\nE:key|K|size=8;proto:0:u8;_pad0:1:u8;port:2:u16;addr:4:u32;\nE|S|size=16;frames:0:u64;delta:8:i32;_pad0:12:u32;\n"
	if !strings.Contains(string(a), strings.ReplaceAll(table, "\n", `\n`)) {
		t.Fatalf("unexpected table in the embedding:\n%s", a)
	}
	schema, _ := os.ReadFile(filepath.Join(d1, "hashio.schema.json"))
	if err := checkRecordsTable(schema, table); err != nil {
		t.Fatalf("the table should match the schema: %v", err)
	}
	for _, bad := range []string{
		strings.Replace(table, "D:key|K|size=8;proto:0:u8;_pad0:1:u8;port:2:u16;", "D:key|K|size=8;proto:0:u8;_pad0:1:u8;port:3:u16;", 1),
		strings.Replace(table, "E:key|K|size=8;proto:0:u8;_pad0:1:u8;port:2:u16;addr:4:u32;\n", "", 1),
	} {
		if err := checkRecordsTable(schema, bad); err == nil {
			t.Errorf("the check passed a tampered table:\n%s", bad)
		} else {
			t.Logf("refused: %v", err)
		}
	}
}
