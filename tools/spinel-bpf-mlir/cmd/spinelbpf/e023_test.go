package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E023 の試験: record の例 lastseen (生成物・selftest の 3 target・veth) と E022 の表の VM の差動 (P006 §5)。

var lastseenArtefacts = []string{"lastseen.mlir", "lastseen.schema.json", "lastseen.maps.json", "lastseen.domain.json", "lastseen.bpf.o",
	"lastseen.compile_warnings.txt", "lastseen_embed.S", "lastseen_embed.o"}

func linkedLastseen(t *testing.T) string {
	t.Helper()
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e023-")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "lastseen", "lastseen.rb"))
	src := filepath.Join(d, "lastseen.rb")
	os.WriteFile(src, b, 0o644)
	r, err := Build(cfg, src)
	if err != nil {
		t.Fatal(err)
	}
	for _, x := range r.Output.Result.Diags {
		t.Errorf("unexpected diagnostic: %s", x)
	}
	exe := filepath.Join(d, "lastseen")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe
}

// TestLastseenArtefacts は E023 の H2: 2 回の build の生成物が commit 済みの物と byte 同じ (埋め込みの record の表を含む)。
func TestLastseenArtefacts(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "lastseen", "lastseen.rb"))
	for i := 0; i < 2; i++ {
		d := t.TempDir()
		src := filepath.Join(d, "lastseen.rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		for _, f := range lastseenArtefacts {
			got, _ := os.ReadFile(filepath.Join(d, f))
			want, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "lastseen", f))
			if err != nil || !bytes.Equal(got, want) {
				t.Errorf("build %d: %s differs from the committed one (%v)", i, f, err)
			}
		}
	}
}

// TestLastseenSelftestHost は E023 の H3 (host、root)。
func TestLastseenSelftestHost(t *testing.T) {
	parallel(t) // P018 E075
	out := feed(t, true, "", linkedLastseen(t), "--selftest")
	if !strings.Contains(out, "selftest ok") {
		t.Fatalf("selftest failed:\n%s", out)
	}
	t.Log(out)
}

// TestLastseenVeth は E023 の H4 (host、root)。
func TestLastseenVeth(t *testing.T) {
	parallel(t) // P018 E075・E084: hostnet (pid の netns・interface・subnet) を通る — 類 d の外
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	out, err := sudo(t, "BIN="+linkedLastseen(t), "N=20", "M=5", filepath.Join(repoRoot(), "scripts", "run-lastseen-host.sh"))
	if err != nil || !strings.Contains(out, "RESULT ok") {
		t.Fatalf("err=%v\n%s", err, out)
	}
	t.Log(out)
}

// TestLastseenSelftestVM は E023 の H3 (SPINELBPF_VM=1)。
func TestLastseenSelftestVM(t *testing.T) {
	parallel(t) // P018 E075
	if os.Getenv("SPINELBPF_VM") != "1" {
		t.Skip("SPINELBPF_VM=1 runs the VM targets")
	}
	exe := linkedLastseen(t)
	for _, k := range []string{"6.12.111", "6.6.157"} {
		img := filepath.Join(os.Getenv("HOME"), "kernel-build", "linux-"+k, "arch", "x86", "boot", "bzImage")
		o, err := sudoCmd(t, filepath.Join(repoRoot(), "scripts", "run-bin-vm.sh"), img, exe, "--selftest").CombinedOutput()
		if err != nil || !strings.Contains(string(o), "uname="+k) || !strings.Contains(string(o), "selftest ok") || !strings.Contains(string(o), "rc=0") {
			t.Fatalf("vm %s: %v\n%s", k, err, o)
		}
		t.Logf("vm %s:\n%s", k, o)
	}
}

// TestRecordTableVM は E023 の H5 (SPINELBPF_VM=1): E022 の t_rec の表の kernel の harness を VM の 2 kernel で、host の twin と CRuby と比べ、
// 同じ実行 file の host の出力と byte で比べる。
func TestRecordTableVM(t *testing.T) {
	parallel(t) // P018 E075
	if os.Getenv("SPINELBPF_VM") != "1" {
		t.Skip("SPINELBPF_VM=1 runs the VM targets")
	}
	h := buildHarnesses(t, tRecSrc())
	script, rows := tRecScript()
	dir, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e023t-")
	if err != nil {
		t.Fatal(err)
	}
	kb, _ := os.ReadFile(h.kernelBin)
	writeExec(t, filepath.Join(dir, "t_rec.kernel"), kb)
	os.WriteFile(filepath.Join(dir, "t_rec.script"), []byte(script), 0o644)
	tw := feed(t, false, script, h.twinBin)
	rb := crubyFeed(t, script, h)
	host := feed(t, true, script, filepath.Join(dir, "t_rec.kernel"))
	if tw != rb || tw != host {
		t.Fatalf("host: twin / CRuby / kernel differ")
	}
	for _, k := range []string{"6.12.111", "6.6.157"} {
		img := filepath.Join(os.Getenv("HOME"), "kernel-build", "linux-"+k, "arch", "x86", "boot", "bzImage")
		o, err := sudoCmd(t, filepath.Join(repoRoot(), "scripts", "run-table-vm.sh"), img, dir).CombinedOutput()
		if err != nil {
			t.Fatalf("vm %s: %v\n%s", k, err, o)
		}
		got, err := os.ReadFile(filepath.Join(dir, "t_rec."+k+".out"))
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("vm %s: %d rows — equal to the host twin / CRuby / same-executable host output: %v (%s)", k, rows, string(got) == tw, strings.TrimSpace(string(o)))
		if string(got) != tw {
			a, b := strings.Split(tw, "\n"), strings.Split(string(got), "\n")
			for i := range a {
				if i < len(b) && a[i] != b[i] {
					t.Errorf("vm %s line %d: twin %q kernel %q", k, i, a[i], b[i])
					break
				}
			}
		}
	}
}
