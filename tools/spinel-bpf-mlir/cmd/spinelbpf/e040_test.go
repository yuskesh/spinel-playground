package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E040 の試験: per-CPU の例 protostat と 3 target (P009 §5)。

var protostatArtefacts = []string{"protostat.mlir", "protostat.schema.json", "protostat.maps.json", "protostat.domain.json", "protostat.bpf.o",
	"protostat.compile_warnings.txt", "protostat_embed.S", "protostat_embed.o"}

func linkedProtostat(t *testing.T) string {
	t.Helper()
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e040-")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "protostat", "protostat.rb"))
	src := filepath.Join(d, "protostat.rb")
	os.WriteFile(src, b, 0o644)
	r, err := Build(cfg, src)
	if err != nil {
		t.Fatal(err)
	}
	for _, x := range r.Output.Result.Diags {
		t.Errorf("unexpected diagnostic: %s", x)
	}
	exe := filepath.Join(d, "protostat")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe
}

// TestProtostatArtefacts は E040 の H1: 2 回の build の生成物が commit 済みの物と byte 同じ。
func TestProtostatArtefacts(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "protostat", "protostat.rb"))
	for i := 0; i < 2; i++ {
		d := t.TempDir()
		src := filepath.Join(d, "protostat.rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		for _, f := range protostatArtefacts {
			got, _ := os.ReadFile(filepath.Join(d, f))
			want, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "protostat", f))
			if err != nil || !bytes.Equal(got, want) {
				t.Errorf("build %d: %s differs from the committed one (%v)", i, f, err)
			}
		}
	}
}

// TestProtostatSelftestHost は E040 の H2 (host、root): 9 つの frame の種類ごとの packets / bytes の CPU ごとの和、0 でない slot の数は test run の数以下。
func TestProtostatSelftestHost(t *testing.T) {
	parallel(t) // P018 E075
	out := feed(t, true, "", linkedProtostat(t), "--selftest")
	if !strings.Contains(out, "kind other packets=2 bytes=0 slots=1\nselftest ok") {
		t.Fatalf("selftest failed:\n%s", out)
	}
	t.Log(out)
}

// TestProtostatVeth は E040 の H3 (host、root): veth に attach し UDP 20 と ping 5 — IPv4 UDP の 20 / 580 と ICMP の 5 / 420、他の種類は 0、program が残らない。
func TestProtostatVeth(t *testing.T) {
	parallel(t) // P018 E075・E084: hostnet (pid の netns・interface・subnet) を通る — 類 d の外
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	out, err := sudo(t, "BIN="+linkedProtostat(t), "N=20", "M=5", filepath.Join(repoRoot(), "scripts", "run-protostat-host.sh"))
	if err != nil || !strings.Contains(out, "RESULT ok") {
		t.Fatalf("err=%v\n%s", err, out)
	}
	t.Log(out)
}

// TestProtostatSelftestVM は E040 の H2 (SPINELBPF_VM=1): 同じ実行 file の selftest を VM の 6.12.111 と 6.6.157 で。
func TestProtostatSelftestVM(t *testing.T) {
	parallel(t) // P018 E075
	if os.Getenv("SPINELBPF_VM") != "1" {
		t.Skip("SPINELBPF_VM=1 runs the VM targets")
	}
	exe := linkedProtostat(t)
	for _, k := range []string{"6.12.111", "6.6.157"} {
		img := filepath.Join(os.Getenv("HOME"), "kernel-build", "linux-"+k, "arch", "x86", "boot", "bzImage")
		o, err := sudoCmd(t, filepath.Join(repoRoot(), "scripts", "run-bin-vm.sh"), img, exe, "--selftest").CombinedOutput()
		if err != nil || !strings.Contains(string(o), "uname="+k) || !strings.Contains(string(o), "kind other packets=2 bytes=0 slots=1\nselftest ok") || !strings.Contains(string(o), "rc=0") {
			t.Fatalf("vm %s: %v\n%s", k, err, o)
		}
		t.Logf("vm %s:\n%s", k, o)
	}
}

// TestPercpuTableVM は E040 の H4 (SPINELBPF_VM=1): E039 の t_pcpu の表の kernel の harness を VM の 2 kernel で (VM の中も taskset -c 0 — `.pin`)、host の twin と byte で比べる。
func TestPercpuTableVM(t *testing.T) {
	parallel(t) // P018 E075
	if os.Getenv("SPINELBPF_VM") != "1" {
		t.Skip("SPINELBPF_VM=1 runs the VM targets")
	}
	h := buildHarnesses(t, tPcpuSrc())
	script := tPcpuScript()
	dir, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e040t-")
	if err != nil {
		t.Fatal(err)
	}
	kb, _ := os.ReadFile(h.kernelBin)
	writeExec(t, filepath.Join(dir, "t_pcpu.kernel"), kb)
	os.WriteFile(filepath.Join(dir, "t_pcpu.script"), []byte(script), 0o644)
	os.WriteFile(filepath.Join(dir, "t_pcpu.pin"), nil, 0o644)
	tw := feed(t, false, script, h.twinBin)
	for _, k := range []string{"6.12.111", "6.6.157"} {
		img := filepath.Join(os.Getenv("HOME"), "kernel-build", "linux-"+k, "arch", "x86", "boot", "bzImage")
		o, err := sudoCmd(t, filepath.Join(repoRoot(), "scripts", "run-table-vm.sh"), img, dir).CombinedOutput()
		if err != nil {
			t.Fatalf("vm %s: %v\n%s", k, err, o)
		}
		got, err := os.ReadFile(filepath.Join(dir, "t_pcpu."+k+".out"))
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("vm %s: %d lines — equal to the host twin: %v (%s)", k, strings.Count(tw, "\n"), string(got) == tw, strings.TrimSpace(string(o)))
		if d := ringDiff(tw, string(got)); d != "" {
			t.Errorf("vm %s: %s", k, d)
		}
	}
}
