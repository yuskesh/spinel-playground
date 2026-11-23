package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E086 の試験 (P021): 照合の対照 — 利用者の source の kernel の struct の宣言の幅・符号・名前・tracepoint の引数の型を 1 つずつ変えた program の load が
// TargetRejected で止まる (frontend は幅・符号・名前を知らず build は通る — 照合だけが守る)。attach はしない (E087)。

const tloadUser = `
require "spinelbpf"

begin
  obj = SpinelBPF.load_embedded
  puts "load ok unmet=#{obj.unmet.length}"
  obj.close
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
end
`

// tpbtfLoad は pos の tp_btf の source を rewrite して user 空間の load を足した program を build・link し root で走らせた出力。
func tpbtfLoad(t *testing.T, name string, rewrite func(string) string) string {
	t.Helper()
	cfg, _ := defaultConfig()
	b, err := os.ReadFile(filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", name+".rb"))
	if err != nil {
		t.Fatal(err)
	}
	src := rewrite(string(b))
	d := t.TempDir()
	p := filepath.Join(d, "tload.rb")
	os.WriteFile(p, []byte(src+tloadUser), 0o644)
	if _, err := Build(cfg, p); err != nil {
		t.Fatalf("%s: build: %v", name, err)
	}
	exe := filepath.Join(d, "tload")
	if err := Link(cfg, p, exe); err != nil {
		t.Fatal(err)
	}
	return feed(t, true, "", exe)
}

// TestTpBtfLoadControls は E086 の H3 (host、root): 正しい宣言の load は通り、変えた宣言は照合が止める (kfield / attach)。
func TestTpBtfLoadControls(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	same := func(s string) string { return s }
	for _, c := range []struct {
		name, prog     string
		rewrite        func(string) string
		want, wantKind string
	}{
		{"control fork", "tpbtf_fork", same, "load ok unmet=", ""},
		{"control switch", "tpbtf_switch", same, "load ok unmet=", ""},
		{"width start_time :u32", "tpbtf_fork", func(s string) string {
			return strings.Replace(s, "start_time: :u64", "start_time: :u32", 1)
		}, "load kind=SpinelBPF::TargetRejected", "start_time as u32"},
		{"sign migration_disabled :i16", "tpbtf_fork", func(s string) string {
			return strings.Replace(s, "migration_disabled: :u16", "migration_disabled: :i16", 1)
		}, "load kind=SpinelBPF::TargetRejected", "migration_disabled as i16"},
		{"name tgid -> tgidd", "tpbtf_fork", func(s string) string {
			s = strings.Replace(s, ":tgid, :start_time", ":tgidd, :start_time", 1)
			s = strings.Replace(s, "tgid: :i32", "tgidd: :i32", 1)
			return strings.ReplaceAll(s, ".load.tgid ", ".load.tgidd ")
		}, "load kind=SpinelBPF::TargetRejected", "no field tgidd"},
		{"tracepoint arg prev_state :i32", "tpbtf_switch", func(s string) string {
			return strings.Replace(s, "3 => :u32", "3 => :i32", 1)
		}, "load kind=SpinelBPF::TargetRejected", "argument 3"},
	} {
		out := tpbtfLoad(t, c.prog, c.rewrite)
		t.Logf("%s: %s", c.name, firstLines(out, 3))
		if !strings.Contains(out, c.want) || (c.wantKind != "" && !strings.Contains(out, c.wantKind)) {
			t.Errorf("%s: want %q and %q, got\n%s", c.name, c.want, c.wantKind, out)
		}
	}
}
