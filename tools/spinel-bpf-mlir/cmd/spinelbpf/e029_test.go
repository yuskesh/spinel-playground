package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E029 の試験: ring buffer の例 pktlog と 3 target (P007 §5)。

var pktlogArtefacts = []string{"pktlog.mlir", "pktlog.schema.json", "pktlog.maps.json", "pktlog.domain.json", "pktlog.bpf.o",
	"pktlog.compile_warnings.txt", "pktlog_embed.S", "pktlog_embed.o"}

func linkedPktlog(t *testing.T) string {
	t.Helper()
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e029-")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "pktlog", "pktlog.rb"))
	src := filepath.Join(d, "pktlog.rb")
	os.WriteFile(src, b, 0o644)
	r, err := Build(cfg, src)
	if err != nil {
		t.Fatal(err)
	}
	for _, x := range r.Output.Result.Diags {
		t.Errorf("unexpected diagnostic: %s", x)
	}
	exe := filepath.Join(d, "pktlog")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe
}

// TestPktlogArtefacts は E029 の H1: 2 回の build の生成物が commit 済みの物と byte 同じ。
func TestPktlogArtefacts(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "pktlog", "pktlog.rb"))
	for i := 0; i < 2; i++ {
		d := t.TempDir()
		src := filepath.Join(d, "pktlog.rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		for _, f := range pktlogArtefacts {
			got, _ := os.ReadFile(filepath.Join(d, f))
			want, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "pktlog", f))
			if err != nil || !bytes.Equal(got, want) {
				t.Errorf("build %d: %s differs from the committed one (%v)", i, f, err)
			}
		}
	}
}

// TestPktlogSelftestHost は E029 の H2 (host、root): 4 つの frame の event と、読まずに 200 回で event 170・落ち 30。
func TestPktlogSelftestHost(t *testing.T) {
	parallel(t) // P018 E075
	out := feed(t, true, "", linkedPktlog(t), "--selftest")
	if !strings.Contains(out, "fill: sent=200 events=170 drops=30\nselftest ok") {
		t.Fatalf("selftest failed:\n%s", out)
	}
	t.Log(out)
}

// TestPktlogVeth は E029 の H3 (host、root): veth に attach し UDP 20 と ping 5 — IPv4 の event 25 (UDP 20・ICMP 5)、drops 0、program が残らない。
func TestPktlogVeth(t *testing.T) {
	parallel(t) // P018 E075・E084: hostnet (pid の netns・interface・subnet) を通る — 類 d の外
	out, err := sudo(t, "BIN="+linkedPktlog(t), "N=20", "M=5", filepath.Join(repoRoot(), "scripts", "run-pktlog-host.sh"))
	if err != nil || !strings.Contains(out, "RESULT ok") {
		t.Fatalf("err=%v\n%s", err, out)
	}
	t.Log(out)
}

// TestPktlogSelftestVM は E029 の H2 (SPINELBPF_VM=1): 同じ実行 file の selftest を VM の 6.12.111 と 6.6.157 で。
func TestPktlogSelftestVM(t *testing.T) {
	parallel(t) // P018 E075
	if os.Getenv("SPINELBPF_VM") != "1" {
		t.Skip("SPINELBPF_VM=1 runs the VM targets")
	}
	exe := linkedPktlog(t)
	for _, k := range []string{"6.12.111", "6.6.157"} {
		img := filepath.Join(os.Getenv("HOME"), "kernel-build", "linux-"+k, "arch", "x86", "boot", "bzImage")
		o, err := sudoCmd(t, filepath.Join(repoRoot(), "scripts", "run-bin-vm.sh"), img, exe, "--selftest").CombinedOutput()
		if err != nil || !strings.Contains(string(o), "uname="+k) || !strings.Contains(string(o), "fill: sent=200 events=170 drops=30\nselftest ok") || !strings.Contains(string(o), "rc=0") {
			t.Fatalf("vm %s: %v\n%s", k, err, o)
		}
		t.Logf("vm %s:\n%s", k, o)
	}
}

// TestRingTableVM は E029 の H4 (SPINELBPF_VM=1): E028 の t_ring の表の kernel の harness (同じ実行 file) を VM の 2 kernel で走らせ、host の twin と byte で比べる。
func TestRingTableVM(t *testing.T) {
	parallel(t) // P018 E075
	if os.Getenv("SPINELBPF_VM") != "1" {
		t.Skip("SPINELBPF_VM=1 runs the VM targets")
	}
	h := buildHarnesses(t, tRingSrc())
	script := tRingScript()
	dir, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e029t-")
	if err != nil {
		t.Fatal(err)
	}
	kb, _ := os.ReadFile(h.kernelBin)
	writeExec(t, filepath.Join(dir, "t_ring.kernel"), kb)
	os.WriteFile(filepath.Join(dir, "t_ring.script"), []byte(script), 0o644)
	tw := feed(t, false, script, h.twinBin)
	host := feed(t, true, script, filepath.Join(dir, "t_ring.kernel"))
	if d := ringDiff(tw, host); d != "" {
		t.Fatalf("host: twin / kernel differ: %s", d)
	}
	for _, k := range []string{"6.12.111", "6.6.157"} {
		img := filepath.Join(os.Getenv("HOME"), "kernel-build", "linux-"+k, "arch", "x86", "boot", "bzImage")
		o, err := sudoCmd(t, filepath.Join(repoRoot(), "scripts", "run-table-vm.sh"), img, dir).CombinedOutput()
		if err != nil {
			t.Fatalf("vm %s: %v\n%s", k, err, o)
		}
		got, err := os.ReadFile(filepath.Join(dir, "t_ring."+k+".out"))
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("vm %s: %d lines — equal to the host twin: %v (%s)", k, strings.Count(tw, "\n"), string(got) == tw, strings.TrimSpace(string(o)))
		if d := ringDiff(tw, string(got)); d != "" {
			t.Errorf("vm %s: %s", k, d)
		}
	}
}
