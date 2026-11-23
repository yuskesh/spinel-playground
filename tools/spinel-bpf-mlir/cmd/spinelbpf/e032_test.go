package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// E032 の試験: hash の系の map の frontend (P008 §1・§2)。

// TestHashStatusTable は E032 の H3 (host、root): 4 つの program を順に test run し、insert / replace / update / delete / add_or_init の status と値、
// hash の満杯の −E2BIG と lru_hash の追い出し (0)、record の key の 2 つの record.make が同じ entry を指すことを、status を書いた array の map で読む。
func TestHashStatusTable(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e032-")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "hash", "hstatus.rb"))
	src := filepath.Join(d, "hstatus.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "hstatus")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	want, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "hash", "hstatus.want"))
	out := feed(t, true, "", exe)
	if out != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", out, want)
	}
}

// TestErrnoConsts は E032 の H3 の定数: bpf.rb の BPF::ENOENT / E2BIG / ENOMEM / EEXIST が CRuby の Errno の値の負と一致する。
func TestErrnoConsts(t *testing.T) {
	parallel(t) // P018 E075
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "ruby", "lib", "bpf.rb"))
	re := regexp.MustCompile(`(?m)^  (ENOENT|E2BIG|ENOMEM|EEXIST) = (-\d+)$`)
	ms := re.FindAllStringSubmatch(string(b), -1)
	if len(ms) != 4 {
		t.Fatalf("bpf.rb has %d errno constants, want 4", len(ms))
	}
	for _, m := range ms {
		out, err := exec.Command("ruby", "-e", "puts(-Errno::"+m[1]+"::Errno)").Output()
		if err != nil {
			t.Fatal(err)
		}
		if strings.TrimSpace(string(out)) != m[2] {
			t.Errorf("BPF::%s = %s, CRuby -Errno::%s::Errno = %s", m[1], m[2], m[1], strings.TrimSpace(string(out)))
		}
	}
}
