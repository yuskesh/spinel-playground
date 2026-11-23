package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E036 の試験: hash の例 flowcount と 3 target (P008 §6)。

var flowcountArtefacts = []string{"flowcount.mlir", "flowcount.schema.json", "flowcount.maps.json", "flowcount.domain.json", "flowcount.bpf.o",
	"flowcount.compile_warnings.txt", "flowcount_embed.S", "flowcount_embed.o"}

func linkedFlowcount(t *testing.T) string {
	t.Helper()
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e036-")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "flowcount", "flowcount.rb"))
	src := filepath.Join(d, "flowcount.rb")
	os.WriteFile(src, b, 0o644)
	r, err := Build(cfg, src)
	if err != nil {
		t.Fatal(err)
	}
	for _, x := range r.Output.Result.Diags {
		t.Errorf("unexpected diagnostic: %s", x)
	}
	exe := filepath.Join(d, "flowcount")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe
}

// TestFlowcountArtefacts は E036 の H1: 2 回の build の生成物が commit 済みの物と byte 同じ。
func TestFlowcountArtefacts(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "flowcount", "flowcount.rb"))
	for i := 0; i < 2; i++ {
		d := t.TempDir()
		src := filepath.Join(d, "flowcount.rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		for _, f := range flowcountArtefacts {
			got, _ := os.ReadFile(filepath.Join(d, f))
			want, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "flowcount", f))
			if err != nil || !bytes.Equal(got, want) {
				t.Errorf("build %d: %s differs from the committed one (%v)", i, f, err)
			}
		}
	}
}

// TestFlowcountSelftestHost は E036 の H2 (host、root): 6 つの frame から 4 つの flow (UDP 2 frame・TCP・ICMP・IHL 6 の UDP は port 0)、IPv6 は数えない、Errs 0。
func TestFlowcountSelftestHost(t *testing.T) {
	parallel(t) // P018 E075
	out := feed(t, true, "", linkedFlowcount(t), "--selftest")
	if !strings.Contains(out, "flows=4 errs=0\nselftest ok") {
		t.Fatalf("selftest failed:\n%s", out)
	}
	t.Log(out)
}

// TestFlowcountVeth は E036 の H3 (host、root): veth に attach し UDP 20 と ping 5 — flow はちょうど 2 つ (UDP 9999 の 20 / 580 と ICMP の 5 / 420)、errs 0、program が残らない。
func TestFlowcountVeth(t *testing.T) {
	parallel(t) // P018 E075・E084: hostnet (pid の netns・interface・subnet) を通る — 類 d の外
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	out, err := sudo(t, "BIN="+linkedFlowcount(t), "N=20", "M=5", filepath.Join(repoRoot(), "scripts", "run-flowcount-host.sh"))
	if err != nil || !strings.Contains(out, "RESULT ok") {
		t.Fatalf("err=%v\n%s", err, out)
	}
	t.Log(out)
}

// TestFlowcountSelftestVM は E036 の H2 (SPINELBPF_VM=1): 同じ実行 file の selftest を VM の 6.12.111 と 6.6.157 で。
func TestFlowcountSelftestVM(t *testing.T) {
	parallel(t) // P018 E075
	if os.Getenv("SPINELBPF_VM") != "1" {
		t.Skip("SPINELBPF_VM=1 runs the VM targets")
	}
	exe := linkedFlowcount(t)
	for _, k := range []string{"6.12.111", "6.6.157"} {
		img := filepath.Join(os.Getenv("HOME"), "kernel-build", "linux-"+k, "arch", "x86", "boot", "bzImage")
		o, err := sudoCmd(t, filepath.Join(repoRoot(), "scripts", "run-bin-vm.sh"), img, exe, "--selftest").CombinedOutput()
		if err != nil || !strings.Contains(string(o), "uname="+k) || !strings.Contains(string(o), "flows=4 errs=0\nselftest ok") || !strings.Contains(string(o), "rc=0") {
			t.Fatalf("vm %s: %v\n%s", k, err, o)
		}
		t.Logf("vm %s:\n%s", k, o)
	}
}

// TestHashTableVM は E036 の H4 (SPINELBPF_VM=1): E034 の t_hash の表の kernel の harness (同じ実行 file) を VM の 2 kernel で走らせ、host の twin と byte で比べる。
func TestHashTableVM(t *testing.T) {
	parallel(t) // P018 E075
	if os.Getenv("SPINELBPF_VM") != "1" {
		t.Skip("SPINELBPF_VM=1 runs the VM targets")
	}
	h := buildHarnesses(t, tHashSrc())
	script := tHashScript()
	dir, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e036t-")
	if err != nil {
		t.Fatal(err)
	}
	kb, _ := os.ReadFile(h.kernelBin)
	writeExec(t, filepath.Join(dir, "t_hash.kernel"), kb)
	os.WriteFile(filepath.Join(dir, "t_hash.script"), []byte(script), 0o644)
	tw := feed(t, false, script, h.twinBin)
	host := feed(t, true, script, filepath.Join(dir, "t_hash.kernel"))
	if d := ringDiff(tw, host); d != "" {
		t.Fatalf("host: twin / kernel differ: %s", d)
	}
	for _, k := range []string{"6.12.111", "6.6.157"} {
		img := filepath.Join(os.Getenv("HOME"), "kernel-build", "linux-"+k, "arch", "x86", "boot", "bzImage")
		o, err := sudoCmd(t, filepath.Join(repoRoot(), "scripts", "run-table-vm.sh"), img, dir).CombinedOutput()
		if err != nil {
			t.Fatalf("vm %s: %v\n%s", k, err, o)
		}
		got, err := os.ReadFile(filepath.Join(dir, "t_hash."+k+".out"))
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("vm %s: %d lines — equal to the host twin: %v (%s)", k, strings.Count(tw, "\n"), string(got) == tw, strings.TrimSpace(string(o)))
		if d := ringDiff(tw, string(got)); d != "" {
			t.Errorf("vm %s: %s", k, d)
		}
	}
}
