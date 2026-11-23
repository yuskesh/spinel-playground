package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// E004 の試験: 1 つの実行 file (spinelbpf build -o)・NEEDED の照合・selftest・host の veth の attach・ebpf-compile が無いときの再利用。
// root の試験は `sudo -n` (SPINELBPF_NO_ROOT=1 のときだけ飛ばす — 黙って飛ばさない)。

var (
	exeOnce sync.Once
	exePath string
	exeErr  error
)

// linkedExample は examples/xdpcount の実行 file を build/tmp に 1 度だけ作る (生成物は例の directory のもの — golden の試験が一致を見ている)。
func linkedExample(t *testing.T) string {
	t.Helper()
	exeOnce.Do(func() {
		cfg, err := defaultConfig()
		if err != nil {
			exeErr = err
			return
		}
		dir, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e004-")
		if err != nil {
			exeErr = err
			return
		}
		src := copyExample(t, dir)
		if _, err := Build(cfg, src); err != nil {
			exeErr = err
			return
		}
		exePath = filepath.Join(dir, "xdpcount")
		exeErr = Link(cfg, src, exePath)
	})
	if exeErr != nil {
		t.Fatal(exeErr)
	}
	return exePath
}

func sudo(t *testing.T, args ...string) (string, error) {
	t.Helper()
	if os.Getenv("SPINELBPF_NO_ROOT") == "1" {
		t.Skip("SPINELBPF_NO_ROOT=1")
	}
	out, err := sudoCmd(t, args...).CombinedOutput()
	return string(out), err
}

// TestLinkNeeded は E004 の H1: NEEDED が libm・libcrypt・libc の 3 つで RUNPATH が無い (Link の中の照合が通った上で、並びも固定)。
func TestLinkNeeded(t *testing.T) {
	parallel(t) // P018 E075
	exe := linkedExample(t)
	out, err := exec.Command("readelf", "-d", exe).Output()
	if err != nil {
		t.Fatal(err)
	}
	var libs []string
	for _, l := range strings.Split(string(out), "\n") {
		if i := strings.Index(l, "Shared library: ["); i >= 0 {
			libs = append(libs, strings.TrimSuffix(l[i+len("Shared library: ["):], "]"))
		}
		if strings.Contains(l, "RUNPATH") || strings.Contains(l, "RPATH") {
			t.Errorf("unexpected %s", l)
		}
	}
	if strings.Join(libs, ",") != "libm.so.6,libcrypt.so.1,libc.so.6" {
		t.Fatalf("NEEDED: %v", libs)
	}
	st, _ := os.Stat(exe)
	t.Logf("executable: %d bytes, NEEDED %v", st.Size(), libs)
}

// TestCheckNeededRejects は NEEDED の照合の負の対照: 一覧に無い .so を持つ実行 file (/usr/bin/ls — libselinux・libcap) で止まる。
func TestCheckNeededRejects(t *testing.T) {
	parallel(t) // P018 E075
	allow, err := readAllow(filepath.Join(repoRoot(), "packaging", "needed.allow"))
	if err != nil {
		t.Fatal(err)
	}
	err = CheckNeeded("/usr/bin/ls", allow)
	if err == nil || !strings.Contains(err.Error(), "libselinux.so.1") {
		t.Fatalf("want a refusal naming libselinux.so.1, got %v", err)
	}
}

// TestSelftest は E004 の H4: root で 100 回の test run が戻り値 2・Counts[0] == Counts[1] == 100、非 root は PrecheckFailed で rc ≠ 0。
func TestSelftest(t *testing.T) {
	parallel(t) // P018 E075
	exe := linkedExample(t)
	if os.Geteuid() != 0 {
		out, err := exec.Command(exe, "--selftest", "10").CombinedOutput()
		if err == nil || !strings.Contains(string(out), "SpinelBPF::PrecheckFailed") {
			t.Fatalf("a non-root selftest must stop at the load: err=%v\n%s", err, out)
		}
	}
	out, err := sudo(t, exe, "--selftest", "100")
	if err != nil || !strings.Contains(out, "selftest: ret=2 counts[0]=100 counts[1]=100") || !strings.Contains(out, "selftest ok") {
		t.Fatalf("err=%v\n%s", err, out)
	}
}

// TestHostAttach は E004 の H3: veth に attach し UDP を 20 個 — counts[0] == 20・0 < counts[1] ≤ counts[0]・終了の後に program が残らない (3 回)。
func TestHostAttach(t *testing.T) {
	parallel(t) // P018 E075・E084: hostnet (pid の netns・interface・subnet) を通る — 類 d の外
	exe := linkedExample(t)
	script := filepath.Join(repoRoot(), "scripts", "run-xdpcount-host.sh")
	for i := 0; i < 3; i++ {
		out, err := sudo(t, "BIN="+exe, "M=20", script)
		if err != nil || !strings.Contains(out, "RESULT ok") {
			t.Fatalf("run %d: err=%v\n%s", i, err, out)
		}
		for _, l := range strings.Split(out, "\n") {
			if strings.HasPrefix(l, "counts[0]=") {
				t.Logf("run %d: %s", i, l)
			}
		}
	}
}

// TestReuseCommitted は E004 の H5 の build の側: ebpf-compile の系が無いとき、生成し直した物が commit 済みの物と同じなら commit 済みの ELF を使い、
// eBPF の側を変えた source では「ebpf-compile が要る」で止まる。
func TestReuseCommitted(t *testing.T) {
	parallel(t) // P018 E075
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	cfg.EbpfCompile = "/nonexistent/ebpf-compile"
	cfg.SchemaCheck = "/nonexistent/ebpf-schema-check"
	d := t.TempDir()
	src := copyExample(t, d)
	for _, f := range []string{"xdpcount.mlir", "xdpcount.schema.json", "xdpcount.maps.json", "xdpcount.bpf.o", "xdpcount_embed.o", "xdpcount.compile_warnings.txt"} { // compile_warnings.txt は E013 (P003 §2) から
		b, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "xdpcount", f))
		if err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(d, f), b, 0o644)
	}
	r, err := Build(cfg, src)
	if err != nil || !r.Reused {
		t.Fatalf("want the committed artefacts reused, got %v (reused=%v)", err, r != nil && r.Reused)
	}
	// eBPF の側を変える (atomic_add の delta 1 → 2)
	text, _ := os.ReadFile(src)
	os.WriteFile(src, []byte(strings.Replace(string(text), "Counts.atomic_add(0, 1)", "Counts.atomic_add(0, 2)", 1)), 0o644)
	_, err = Build(cfg, src)
	if err == nil || !strings.Contains(err.Error(), "differs from the committed one") {
		t.Fatalf("want a refusal, got %v", err)
	}
}
