package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E066 の試験: record の配列の member (P016) — 生成物の形・user 空間の平らな並び・双子と kernel。

func recArraySrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "rec_array.rb")
}

// TestRecordArrayShapes は E066 の H1・H2: schema の type(array)・大きさ、requirements の [N]t と offset、.mlir の要素の経路。
func TestRecordArrayShapes(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	b, err := os.ReadFile(recArraySrc())
	if err != nil {
		t.Fatal(err)
	}
	d := t.TempDir()
	src := filepath.Join(d, "rec_array.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	read := func(f string) string {
		x, err := os.ReadFile(filepath.Join(d, f))
		if err != nil {
			t.Fatal(err)
		}
		return strings.Join(strings.Fields(string(x)), " ")
	}
	sc, mj, ml := read("rec_array.schema.json"), read("rec_array.maps.json"), read("rec_array.mlir")
	for _, w := range []string{
		`"symbol": "Hist", "id": 0, "size": 40,`,
		`"name": "hist", "offset": 0, "expose": "int", "note": "", "type": { "kind": "array", "count": 8, "element": { "kind": "int", "bits": 32,`,
		`"name": "v", "offset": 2, "expose": "int", "note": "", "type": { "kind": "array", "count": 3, "element": { "kind": "int", "bits": 16,`,
	} {
		if !strings.Contains(sc, w) {
			t.Errorf("schema lacks %s", w)
		}
	}
	for _, w := range []string{`"name": "hist", "offset": 0, "type": "[8]u32"`, `"name": "n", "offset": 32, "type": "u64"`, `"Pair": { "size": 8,`, `"name": "v", "offset": 2, "type": "[3]u16"`} {
		if !strings.Contains(mj, w) {
			t.Errorf("maps.json lacks %s", w)
		}
	}
	for _, w := range []string{`ebpf.ref.field.load %v2 "hist[3]"`, `ebpf.ref.field.store %v2 "hist[5]"`, `ebpf.ref.field.atomic_add %v2 "hist[2]"`, `"v[2]"`} {
		if !strings.Contains(ml, w) {
			t.Errorf(".mlir lacks %s", w)
		}
	}
}

// TestRecordArrayUserSpace は E066 の H2 の load と H4 (root): map_put_record_values の平らな並び → test run → map_get_record の並びの固定。
func TestRecordArrayUserSpace(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	b, err := os.ReadFile(recArraySrc())
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e066-")
	if err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(d, "rec_array.rb")
	user := `
require "spinelbpf"
obj = SpinelBPF.load_embedded
puts "loaded unmet=#{obj.unmet.length}"
obj.map_put_record_values(Hs, 0, [10, 11, 12, 13, 14, 15, 16, 17, 99])
obj.test_run_xdp("prog", 1)
puts "got=#{obj.map_get_record(Hs, 0).join(",")} out=#{obj.map_get(Out, 0)}"
begin
  obj.map_put_record(Hs, 0, Hist.new(Array.new(8, 0), 0))
  puts "put_struct=ok"
rescue SpinelBPF::ValueRange
  puts "put_struct=ValueRange"
end
obj.close
`
	os.WriteFile(src, append(b, []byte(user)...), 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "rec_array")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe)
	t.Log(out)
	for _, w := range []string{"loaded unmet=0", "got=10,11,13,13,14,7,16,17,99 out=13", "put_struct=ValueRange"} {
		if !strings.Contains(out, w) {
			t.Errorf("want %q", w)
		}
	}
}

// TestRecordArrayHarness は E066 の H5 (root): 要素の poke の行で双子と kernel の dump が一致。
func TestRecordArrayHarness(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildHarnesses(t, recArraySrc())
	var b strings.Builder
	rows := 0
	for _, v := range []string{"0", "1", "4294967295"} {
		for _, n := range []string{"0", "5"} {
			fmt.Fprintf(&b, "echo r%d\nreset\npoke Hs 0 hist[2] %s\npoke Hs 0 hist[3] %s\npoke Hs 0 hist[5] %s\npoke Hs 0 n %s\npoke Ps 1 v[2] %s\npoke Ps 1 a %s\nrun prog\ndump\n", rows, v, v, v, n, n, n)
			rows++
		}
	}
	script := b.String()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	if strings.Contains(tw, "err=") || strings.Contains(kn, "err=") {
		t.Fatalf("an error line — twin:\n%s\nkernel:\n%s", tw, kn)
	}
	d := loopDiff(t, tw, kn, rows)
	for i, s := range d {
		t.Errorf("row %d: twin and kernel differ in %v", i, keysOf(s))
	}
	if !strings.Contains(tw, "Hs[0].hist[5]=7") || !strings.Contains(tw, "Hs[0].hist[2]=2") {
		t.Errorf("the twin dump lacks the element writes:\n%s", tw)
	}
	t.Logf("%d rows, %d differing", rows, len(d))
}
