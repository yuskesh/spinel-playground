package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// E051 の試験 (P013): tracing の正の例 3 つ (fentry・fexit・kprobe) の compile — ELF の requirements の行と kprobe の register の番号の起点。load はしない (bml ② を待つ — E053)。

// elfRequirements は ELF の .ebpf_requirements の text。
func elfRequirements(t *testing.T, cfg Config, elf string) string {
	t.Helper()
	objcopy := filepath.Join(filepath.Dir(cfg.Clang), "llvm-objcopy")
	o, err := exec.Command(objcopy, "--dump-section", ".ebpf_requirements=/dev/stdout", elf).Output()
	if err != nil {
		t.Fatalf("reading .ebpf_requirements of %s: %v", elf, err)
	}
	return string(o)
}

// TestTracingCompile は E051 の H1 と H2: 3 つの正の例が build でき、requirements に kind の行、kprobe の ctx.arg(2) が .mlir・schema・requirements で同じ 2。
func TestTracingCompile(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	for _, c := range []struct {
		name string
		rows []string
	}{
		{"trace_fentry", []string{"attach\ton_test1\ttrace_fentry\tbpf_fentry_test1"}},
		{"trace_fexit", []string{"attach\ton_ret\ttrace_fexit\tbpf_fentry_test1", "retsig\ton_ret\t1\ti32"}},
		{"trace_kprobe", []string{"attach\ton_poll\tkprobe\tdo_sys_poll", "arch\ton_poll\tx86_64", "kprobearg\ton_poll\t2\tu32"}},
	} {
		d := t.TempDir()
		b, err := os.ReadFile(filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", c.name+".rb"))
		if err != nil {
			t.Fatal(err)
		}
		src := filepath.Join(d, c.name+".rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		req := elfRequirements(t, cfg, filepath.Join(d, c.name+".bpf.o"))
		for _, r := range c.rows {
			if !strings.Contains(req, r+"\n") {
				t.Errorf("%s: requirements lack %q:\n%s", c.name, r, req)
			}
		}
		if c.name != "trace_kprobe" {
			continue
		}
		// H2: register の番号の起点 (Ruby の ctx.arg(n) = schema の params の n = .mlir の kprobe.arg の n = requirements の kprobearg の n)
		m, _ := os.ReadFile(filepath.Join(d, c.name+".mlir"))
		mm := regexp.MustCompile(`ebpf\.kprobe\.arg %ctx (\d+) `).FindAllStringSubmatch(string(m), -1)
		var sc struct {
			Core struct {
				Programs []struct {
					Params []struct {
						N int `json:"n"`
					} `json:"params"`
				} `json:"programs"`
			} `json:"core"`
		}
		sj, _ := os.ReadFile(filepath.Join(d, c.name+".schema.json"))
		if err := json.Unmarshal(sj, &sc); err != nil {
			t.Fatal(err)
		}
		if len(mm) != 1 || mm[0][1] != "2" || len(sc.Core.Programs) != 1 || len(sc.Core.Programs[0].Params) != 1 || sc.Core.Programs[0].Params[0].N != 2 {
			t.Errorf("the register number of ctx.arg(2) is not 2 everywhere: mlir %v, schema %+v", mm, sc.Core.Programs)
		}
	}
}
