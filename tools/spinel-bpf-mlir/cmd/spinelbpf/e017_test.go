package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// E017 の試験: EtherType の例 (examples/ethertype) の生成物・selftest の 3 target・veth の attach、E016 の表の VM の差動 (P004 §6)。

var ethertypeArtefacts = []string{"ethertype.mlir", "ethertype.schema.json", "ethertype.maps.json", "ethertype.domain.json", "ethertype.bpf.o",
	"ethertype.compile_warnings.txt", "ethertype_embed.S", "ethertype_embed.o"}

// linkedEthertype は例の 1 つの実行 file (build/tmp に)。
func linkedEthertype(t *testing.T) string {
	t.Helper()
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e017-")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "ethertype", "ethertype.rb"))
	src := filepath.Join(d, "ethertype.rb")
	os.WriteFile(src, b, 0o644)
	r, err := Build(cfg, src)
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range r.Output.Result.Diags {
		t.Errorf("unexpected diagnostic: %s", d)
	}
	exe := filepath.Join(d, "ethertype")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe
}

// TestEthertypeArtefacts は E017 の H1: 2 回の build の生成物が commit 済みの物と byte 同じ。
func TestEthertypeArtefacts(t *testing.T) {
	parallel(t) // P018 E075
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "ethertype", "ethertype.rb"))
	for i := 0; i < 2; i++ {
		d := t.TempDir()
		src := filepath.Join(d, "ethertype.rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		for _, f := range ethertypeArtefacts {
			got, err := os.ReadFile(filepath.Join(d, f))
			if err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "ethertype", f))
			if err != nil || !bytes.Equal(got, want) {
				t.Errorf("build %d: %s differs from the committed one (%v)", i, f, err)
			}
		}
	}
}

// TestEthertypeSelftestHost は E017 の H2 (host、root)。
func TestEthertypeSelftestHost(t *testing.T) {
	parallel(t) // P018 E075
	out := feed(t, true, "", linkedEthertype(t), "--selftest")
	if !strings.Contains(out, "selftest ok") {
		t.Fatalf("selftest failed:\n%s", out)
	}
	t.Log(out)
}

// TestEthertypeVeth は E017 の H3 (host、root): veth に attach し UDP 9999 を 20 個と ping を 5 個。
func TestEthertypeVeth(t *testing.T) {
	parallel(t) // P018 E075・E084: hostnet (pid の netns・interface・subnet) を通る — 類 d の外
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	exe := linkedEthertype(t)
	out, err := sudo(t, "BIN="+exe, "N=20", "M=5", filepath.Join(repoRoot(), "scripts", "run-ethertype-host.sh"))
	if err != nil || !strings.Contains(out, "RESULT ok") {
		t.Fatalf("err=%v\n%s", err, out)
	}
	t.Log(out)
}

// TestEthertypeSelftestVM は E017 の H2 (SPINELBPF_VM=1): 同じ実行 file の selftest を VM 6.12.111 / 6.6.157 で。
func TestEthertypeSelftestVM(t *testing.T) {
	parallel(t) // P018 E075
	if os.Getenv("SPINELBPF_VM") != "1" {
		t.Skip("SPINELBPF_VM=1 runs the VM targets")
	}
	exe := linkedEthertype(t)
	for _, k := range []string{"6.12.111", "6.6.157"} {
		img := filepath.Join(os.Getenv("HOME"), "kernel-build", "linux-"+k, "arch", "x86", "boot", "bzImage")
		o, err := sudoCmd(t, filepath.Join(repoRoot(), "scripts", "run-bin-vm.sh"), img, exe, "--selftest").CombinedOutput()
		if err != nil || !strings.Contains(string(o), "uname="+k) || !strings.Contains(string(o), "selftest ok") || !strings.Contains(string(o), "rc=0") {
			t.Fatalf("vm %s: %v\n%s", k, err, o)
		}
		t.Logf("vm %s:\n%s", k, o)
	}
}

// TestPacketTableVM は E017 の H4 (SPINELBPF_VM=1): E016 の表の kernel の harness を VM の 2 kernel で走らせ、host の twin と CRuby と比べ、
// 同じ実行 file の host の出力と VM の出力が byte 一致することを見る。
func TestPacketTableVM(t *testing.T) {
	parallel(t) // P018 E075
	if os.Getenv("SPINELBPF_VM") != "1" {
		t.Skip("SPINELBPF_VM=1 runs the VM targets")
	}
	dir, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e017t-")
	if err != nil {
		t.Fatal(err)
	}
	pos := filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos")
	type tbl struct {
		name, src string
		rows      []pktRow
		prog      string
		dl        int
		twin, rb  string
	}
	var tables []*tbl
	for _, name := range []string{"pkt_ether", "pkt_nested", "pkt_bounds", "pkt_off_masked", "t_pkt"} {
		tb := &tbl{name: name, src: filepath.Join(pos, name+".rb")}
		for s := 0; s < 3; s++ {
			if name == "t_pkt" {
				tb.src = tPktSrc()
				tb.rows = append(tb.rows, tPktRows(s)...)
			} else {
				tb.rows = append(tb.rows, pktRows(name, s)...)
			}
		}
		tables = append(tables, tb)
	}
	cfg, _ := defaultConfig()
	for _, tb := range tables {
		h := buildHarnesses(t, tb.src)
		text, _ := os.ReadFile(tb.src)
		res := analyzeOrFail(t, cfg, tb.src, string(text))
		tb.prog, tb.dl = res.Programs[0].Name, dumpLines(res)
		script := pktScript(tb.prog, tb.rows)
		tb.twin = feed(t, false, script, h.twinBin)
		tb.rb = crubyFeed(t, script, h)
		kb, _ := os.ReadFile(h.kernelBin)
		writeExec(t, filepath.Join(dir, tb.name+".kernel"), kb)
		os.WriteFile(filepath.Join(dir, tb.name+".script"), []byte(script), 0o644)
		// host の同じ実行 file の出力 (VM の出力と byte で比べる)
		os.WriteFile(filepath.Join(dir, tb.name+".host.out"), []byte(feed(t, true, script, filepath.Join(dir, tb.name+".kernel"))), 0o644)
	}
	for _, k := range []string{"6.12.111", "6.6.157"} {
		img := filepath.Join(os.Getenv("HOME"), "kernel-build", "linux-"+k, "arch", "x86", "boot", "bzImage")
		o, err := sudoCmd(t, filepath.Join(repoRoot(), "scripts", "run-table-vm.sh"), img, dir).CombinedOutput()
		if err != nil {
			t.Fatalf("vm %s: %v\n%s", k, err, o)
		}
		t.Logf("vm %s:\n%s", k, strings.TrimSpace(string(o)))
		total, both := 0, 0
		for _, tb := range tables {
			kn, err := os.ReadFile(filepath.Join(dir, tb.name+"."+k+".out"))
			if err != nil {
				t.Fatal(err)
			}
			host, _ := os.ReadFile(filepath.Join(dir, tb.name+".host.out"))
			r := comparePkt(tb.rows, tb.dl, tb.twin, string(kn), tb.rb)
			total, both = total+r.rows, both+r.both
			t.Logf("vm %s %s: %d rows (%d three-way, %d twin-only), %d mismatches, host output byte-equal: %v", k, tb.name, r.rows, r.both, r.short, len(r.bad), bytes.Equal(kn, host))
			for _, b := range first(r.bad, 5) {
				t.Error(b)
			}
			if !bytes.Equal(kn, host) {
				t.Errorf("vm %s %s: the output differs from the host run of the same executable", k, tb.name)
			}
		}
		t.Logf("vm %s: %d rows, %d three-way", k, total, both)
	}
}

func analyzeOrFail(t *testing.T, cfg Config, src, text string) *frontend.Result {
	t.Helper()
	sp := frontend.Spinel{Bin: cfg.Spinel, LibDir: filepath.Join(cfg.Repo, "ruby", "lib")}
	res, err := frontend.Analyze(sp, t.TempDir(), src, text)
	if err != nil || res.Diags.Blocking() {
		t.Fatalf("analyze %s: %v %v", src, err, res.Diags)
	}
	return res
}
