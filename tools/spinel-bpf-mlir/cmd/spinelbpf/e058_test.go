package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E058 の試験 (P014 — host、root): global 変数の user 空間と双子 — 表の差動・ConfigNotSet・load_embedded・値の範囲・変異の対照。

var globNames = []string{"C8", "S8", "C16", "S16", "C32", "S64"}

// globRows は表の行 (必須の 6 つの値、O64 は "" で未設定)。
func globRows() []struct {
	label string
	vals  []string
	o64   string
} {
	return []struct {
		label string
		vals  []string
		o64   string
	}{
		{"zero", []string{"0", "0", "0", "0", "0", "0"}, ""},
		{"max", []string{"255", "127", "65535", "32767", "4294967295", "9223372036854775807"}, "9223372036854775807"},
		{"min", []string{"0", "-128", "0", "-32768", "0", "-9223372036854775807"}, "0"},
		{"minus1", []string{"1", "-1", "1", "-1", "1", "-1"}, ""},
		{"bleed_c16", []string{"0", "0", "65535", "0", "0", "0"}, ""}, // 1 つの global だけ全て 1 — 隣に bits が漏れない (mojo E068)
		{"bleed_s8", []string{"0", "-1", "0", "0", "0", "0"}, ""},
		{"bleed_c32", []string{"0", "0", "0", "0", "4294967295", "0"}, "1"},
	}
}

func globScript(vals []string, o64 string) string {
	var b strings.Builder
	for i, n := range globNames {
		fmt.Fprintf(&b, "config %s %s\n", n, vals[i])
	}
	if o64 != "" {
		fmt.Fprintf(&b, "config O64 %s\n", o64)
	}
	b.WriteString("load\nrun prog\nrun prog\ndump\n")
	return b.String()
}

func globDump(out string) []string {
	var d []string
	for _, l := range strings.Split(out, "\n") {
		if strings.Contains(l, "=") && !strings.HasPrefix(l, "ret=") {
			d = append(d, l)
		}
	}
	return d
}

// TestGlobalsDifferential は E058 の H1・H2: 表の全ての行で双子と kernel の dump (map に写した値・global の行・counter) が一致、
// 必須の Config の未設定は kernel が load で ConfigNotSet (置いていない全ての名前を宣言の順に)、双子は run で誤り。
func TestGlobalsDifferential(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildHarnesses(t, filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "glob", "t_glob.rb"))
	for _, r := range globRows() {
		s := globScript(r.vals, r.o64)
		tw, kn := globDump(feed(t, false, s, h.twinBin)), globDump(feed(t, true, s, h.kernelBin))
		if strings.Join(tw, "\n") != strings.Join(kn, "\n") || len(kn) < 15 {
			t.Errorf("row %s: twin and kernel differ\ntwin:\n%s\nkernel:\n%s", r.label, strings.Join(tw, "\n"), strings.Join(kn, "\n"))
		}
		if r.o64 == "" && !strings.Contains(strings.Join(kn, "\n"), "O64=0\n") {
			t.Errorf("row %s: an unset OptionalConfig must read 0", r.label)
		}
	}
	kn := feed(t, true, "config C8 1\nconfig C16 2\nload\ndump\n", h.kernelBin)
	if !strings.Contains(kn, "load err=SpinelBPF::ConfigNotSet msg=bml: config S8, S16, C32, S64 are not set") {
		t.Errorf("want ConfigNotSet naming S8, S16, C32, S64 in declaration order:\n%s", kn)
	}
	tw := feed(t, false, "config C8 1\nconfig C16 2\nload\nrun prog\n", h.twinBin)
	if !strings.Contains(tw, "err=RuntimeError") {
		t.Errorf("the twin should fail reading an unset Config:\n%s", tw)
	}
}

// runGlobProg は testdata/glob の user の側の program を build して root で走らせる (tamper は build の後の maps.json の書き換え — H5 の m2)。
func runGlobProg(t *testing.T, name string, tamper func(string) string) string {
	t.Helper()
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "glob", name+".rb"))
	src := filepath.Join(d, name+".rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	if tamper != nil {
		mj := filepath.Join(d, name+".maps.json")
		m, _ := os.ReadFile(mj)
		mm := tamper(string(m))
		if mm == string(m) {
			t.Fatal("the maps.json tamper did not apply")
		}
		os.WriteFile(mj, []byte(mm), 0o644)
		if err := runIn(d, cfg.Clang, "-c", "-x", "assembler", name+"_embed.S", "-o", name+"_embed.o"); err != nil {
			t.Fatal(err)
		}
	}
	exe := filepath.Join(d, name)
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out, _ := sudo(t, exe)
	return out
}

// TestGlobalsUserSide は E058 の H3・H4・H6: optional だけの program は load_embedded で 0、必須の在る program の load_embedded は ConfigNotSet、
// set の値の範囲と Counter への set の誤り、load の後の config_get (符号付きは負) と counter_get (i64 の負の加算)。
func TestGlobalsUserSide(t *testing.T) {
	parallel(t) // P018 E075
	requireUnverified(t)
	if out := runGlobProg(t, "opt_only", nil); !strings.Contains(out, "load_embedded kind=OK V=0 out=1") {
		t.Errorf("opt_only:\n%s", out)
	}
	out := runGlobProg(t, "req_only", nil)
	for _, w := range []string{
		"load_embedded kind=SpinelBPF::ConfigNotSet msg=bml: config P, S, U are not set",
		"set P 70000 kind=SpinelBPF::ValueRange", "set S -129 kind=SpinelBPF::ValueRange", "set U -1 kind=SpinelBPF::ValueRange",
		"set counter kind=SpinelBPF::MapMismatch msg=spinelbpf: N is a Counter (.bss)",
		"loaded P=8080 S=-5 U=200 out=8275 N=-15",
	} {
		if !strings.Contains(out, w) {
			t.Errorf("req_only: want %q:\n%s", w, out)
		}
	}
}

// TestGlobalsMapsJSONTamper は E058 の H5 (m2): 埋め込みの maps.json の globals を消した実行 file は load で止まる (黙って load しない)。
func TestGlobalsMapsJSONTamper(t *testing.T) {
	parallel(t) // P018 E075
	requireUnverified(t)
	out := runGlobProg(t, "opt_only", func(m string) string {
		i := strings.Index(m, ",\n  \"globals\"")
		if i < 0 {
			return m
		}
		return m[:i] + "\n}\n"
	})
	t.Log(out)
	if strings.Contains(out, "load_embedded kind=OK") || !strings.Contains(out, "load_embedded kind=SpinelBPF::") {
		t.Errorf("a maps.json without globals must not load silently:\n%s", out)
	}
}
