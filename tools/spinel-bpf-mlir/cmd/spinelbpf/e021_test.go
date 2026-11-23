package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E021 の試験: user 空間の record (bytes の C ABI・埋め込みの layout の表・map_get / map_put — P006 §3)。

// buildRecio は testdata/rec/recio.rb を build し実行 file の path を返す (dir に生成物)。
func buildRecio(t *testing.T) (string, string) {
	t.Helper()
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e021-")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "rec", "recio.rb"))
	src := filepath.Join(d, "recio.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "recio")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe, d
}

// TestRecordRoundTrip は E021 の H2・H3・H4 (host、root): 境界の値の往復 (record の型 2 つが同じ写しの関数を通る — S6 を避けた class.new と to_a)、
// eBPF の側の store / atomic_add の結果、u64 の 2^63・i64 の −2^63 の get と範囲の外・nil・padding の put の ValueRange、誤った put の後に値が変わらない。
func TestRecordRoundTrip(t *testing.T) {
	parallel(t) // P018 E075
	exe, _ := buildRecio(t)
	want, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "rec", "recio.want"))
	out := feed(t, true, "", exe)
	if out != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", out, want)
	}
}

// TestRecordsTable は E021 の H1: 埋め込みの layout の表が schema と一致し (build の検査)、2 回の build で byte 同じ。表を書き換えると検査が名指しで止める。
func TestRecordsTable(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	_, d1 := buildRecio(t)
	_, d2 := buildRecio(t)
	a, _ := os.ReadFile(filepath.Join(d1, "recio_embed.S"))
	b, _ := os.ReadFile(filepath.Join(d2, "recio_embed.S"))
	if len(a) == 0 || string(a) != string(b) || !strings.Contains(string(a), "spinelbpf_records") {
		t.Fatalf("the embedding differs between two builds or lacks the table:\n%s", a)
	}
	schema, _ := os.ReadFile(filepath.Join(d1, "recio.schema.json"))
	table := "Ws|Wide|size=32;u64:0:u64;i64:8:i64;u32:16:u32;i32:20:i32;u16:24:u16;i16:26:i16;u8:28:u8;i8:29:i8;_pad0:30:u16;\nSs|Small|size=4;a:0:u8;_pad0:1:u8;b:2:i16;\n"
	if !strings.Contains(string(a), strings.ReplaceAll(table, "\n", `\n`)) {
		t.Fatalf("unexpected table in the embedding:\n%s", a)
	}
	if err := checkRecordsTable(schema, table); err != nil {
		t.Fatalf("the table should match the schema: %v", err)
	}
	for _, bad := range []string{
		strings.Replace(table, "b:2:i16", "b:2:u16", 1),
		strings.Replace(table, "i8:29:i8", "i8:30:i8", 1),
		"Ws|Wide|size=32;u64:0:u64;i64:8:i64;u32:16:u32;i32:20:i32;u16:24:u16;i16:26:i16;u8:28:u8;i8:29:i8;_pad0:30:u16;\n",
	} {
		if err := checkRecordsTable(schema, bad); err == nil {
			t.Errorf("the check passed a tampered table:\n%s", bad)
		} else {
			t.Logf("refused: %v", err)
		}
	}
}

// TestRecordMapsJSONTamper は E021 の H5 (root): 埋め込みの maps.json の record の member の offset を書き換えた実行 file は、load の段 2' で MapMismatch (record の名前と食い違い)。
func TestRecordMapsJSONTamper(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	_, d := buildRecio(t)
	mj := filepath.Join(d, "recio.maps.json")
	b, _ := os.ReadFile(mj)
	bad := strings.Replace(string(b), "\"name\": \"b\",\n          \"offset\": 2,", "\"name\": \"b\",\n          \"offset\": 1,", 1)
	if bad == string(b) {
		t.Fatalf("the rewrite did not apply:\n%s", b)
	}
	os.WriteFile(mj, []byte(bad), 0o644)
	if err := runIn(d, cfg.Clang, "-c", "-x", "assembler", "recio_embed.S", "-o", "recio_embed.o"); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "recio_bad")
	if err := Link(cfg, filepath.Join(d, "recio.rb"), exe); err != nil {
		t.Fatal(err)
	}
	cmd := sudoCmd(t, exe)
	out, err := cmd.CombinedOutput()
	t.Logf("err=%v\n%s", err, firstLines(string(out), 4))
	if err == nil || !strings.Contains(string(out), "MapMismatch") || !strings.Contains(string(out), "record:Small") {
		t.Fatal("want a MapMismatch at load naming record:Small")
	}
}

// TestRecordNoRegenerate は E021 の H6: Struct / BPF.record を変えた source で、commit 済みの生成物を使う経路 (ebpf-compile の無い clone) は止まる。
func TestRecordNoRegenerate(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	_, d := buildRecio(t)
	src := filepath.Join(d, "recio.rb")
	b, _ := os.ReadFile(src)
	os.WriteFile(src, []byte(strings.Replace(string(b), "BPF.record(Small, a: :u8, _pad0: :u8, b: :i16)", "BPF.record(Small, a: :i8, _pad0: :u8, b: :i16)", 1)), 0o644)
	cfg.EbpfCompile = "/nonexistent/ebpf-compile"
	if _, err := Build(cfg, src); err == nil || !strings.Contains(err.Error(), "differs from the committed one") {
		t.Fatalf("want a refusal, got %v", err)
	} else {
		t.Logf("refused: %v", err)
	}
}
