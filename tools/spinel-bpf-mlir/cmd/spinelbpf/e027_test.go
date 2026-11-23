package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E027 の試験: ring buffer の user 空間の reader (pull 型の C ABI・read_record・状態 — P007 §3)。

// TestRingReader は E027 の H1・H2 (host、root): test run ごとの event を read_record が順に読む (u32 の最大・i32 の負・i16 の負・padding・u64)、
// 空の後の期限 0 / 200 ms は空の Array、閉じた reader・閉じた object の read / open と 2 回目の close は State で process は続く。
func TestRingReader(t *testing.T) {
	parallel(t) // P018 E075
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e027-")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "ring", "ringio.rb"))
	src := filepath.Join(d, "ringio.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "ringio")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	want, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "ring", "ringio.want"))
	out := feed(t, true, "", exe)
	if out != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", out, want)
	}
}

// TestRingReaderTableTamper は E027 の負の対照 (root): 埋め込みの layout の表の ring buffer の行の大きさを書き換えた実行 file は、
// 最初の read_record で MapMismatch (event の長さと呼び手の record の大きさの食い違い — 黙って切り詰めない)。
func TestRingReaderTableTamper(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e027-")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "ring", "ringio.rb"))
	src := filepath.Join(d, "ringio.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	es := filepath.Join(d, "ringio_embed.S")
	e, _ := os.ReadFile(es)
	bad := strings.Replace(string(e), "Events|Ev|size=24", "Events|Ev|size=16", 1)
	if bad == string(e) {
		t.Fatalf("the rewrite did not apply")
	}
	os.WriteFile(es, []byte(bad), 0o644)
	if err := runIn(d, cfg.Clang, "-c", "-x", "assembler", "ringio_embed.S", "-o", "ringio_embed.o"); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "ringio_bad")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	if os.Getenv("SPINELBPF_NO_ROOT") == "1" {
		t.Skip("SPINELBPF_NO_ROOT=1")
	}
	out, err := sudoCmd(t, exe).CombinedOutput()
	t.Logf("err=%v\n%s", err, firstLines(string(out), 4))
	if err == nil || !strings.Contains(string(out), "MapMismatch") || !strings.Contains(string(out), "24 bytes but the caller's record layout is 16") || strings.Contains(string(out), "e1 ") {
		t.Fatal("want a MapMismatch at the first read naming both sizes")
	}
}
