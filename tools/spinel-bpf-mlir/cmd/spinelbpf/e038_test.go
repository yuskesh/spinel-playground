package main

import (
	"os"
	"path/filepath"
	"testing"
)

// E038 の試験: per-CPU の map の frontend と user 空間 (P009 §1〜§3)。

// TestPercpuSemantics は E038 の H3 (host、root): process を taskset で CPU 2 に固定し、program の加算は CPU 2 の slot にだけ入り (record・整数・hash の add_or_init)、
// percpu_hash の新しい element の他の CPU の slot は 0、user 空間の CPU ごとの put / get の往復 (12 byte の record)、sum、delete / keys / has、種類の食い違いは MapMismatch。
func TestPercpuSemantics(t *testing.T) {
	parallel(t) // P018 E075
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e038-")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "percpu", "percpuio.rb"))
	src := filepath.Join(d, "percpuio.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "percpuio")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	want, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "percpu", "percpuio.want"))
	out := feed(t, true, "", "taskset", "-c", "2", exe)
	if out != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", out, want)
	}
}
