package frontend

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E157 の試験 (P029 §2 段 4): uprobe の pointer の引数 (`:ptr` — raw の i64、bpf-mlir E559 の形式 18 の uprobearg ptr)。

// TestUprobePtrPositive は H1: up_libc_lock (libc の pthread_mutex_lock の `1 => :ptr`) が生成でき bpf-mlir の道具を通り、build の時の照合の Unmet 0。
// .mlir は `ebpf.uprobe.arg … -> i64`、schema の param の型は ptr、requirements は形式 18 で `uprobearg on_lock 1 ptr`、unlock (params: {}) は uprobearg を持たない。
func TestUprobePtrPositive(t *testing.T) {
	sp := testSpinel(t)
	out, err := Generate(sp, t.TempDir(), filepath.Join("testdata", "uprobe", "up_libc_lock.rb"))
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	elf := compileAll(t, out)
	if err := UprobeBuildCheck(elf, out.Result); err != nil {
		t.Errorf("the build-time check refused the :ptr program: %v", err)
	}
	if !strings.Contains(out.MLIR, `ebpf.uprobe.arg %ctx 1 : !ebpf.ctx<"uprobe"> -> i64`) {
		t.Errorf("the .mlir lacks the i64 uprobe.arg of the :ptr parameter")
	}
	if !strings.Contains(string(out.Schema), `"kind": "ptr"`) {
		t.Errorf("the schema lacks the ptr parameter type")
	}
	if !bytes.Contains(elf, []byte("ebpf-requirements 18\n")) || !bytes.Contains(elf, []byte("uprobearg\ton_lock\t1\tptr\n")) || bytes.Contains(elf, []byte("uprobearg\ton_unlock")) {
		t.Errorf("the ELF requirements: want format 18 with `uprobearg on_lock 1 ptr` and no uprobearg for on_unlock")
	}
}

// ptrSrc は cfix の関数 sym の引数 1 を :ptr で読む uprobe (H2 の build の照合)。
func ptrSrc(sym, rest string) string {
	return `require "bpf"

Seen = BPF::ArrayMap.new("Seen", :i64, 1)

def on_p(ctx)
  Seen.update(0, ctx.arg(1))
end
BPF.uprobe :on_p, "target/cfix", "` + sym + `", params: {1 => :ptr` + rest + `}
`
}

// TestUprobePtrBuild は H2 の build の照合の 2 行: cfix の sum_args の引数 1 (int64_t) を :ptr で読むと SB032 の uprobearg (non-pointer — 宣言の位置)、
// greet の引数 1 (const char *) は深さ 1・8 byte の pointer なので通る (strptr との違いは読み方だけ)。
func TestUprobePtrBuild(t *testing.T) {
	sp := testSpinel(t)
	b, _ := os.ReadFile(filepath.Join("testdata", "uprobe", "target", "cfix"))
	for _, c := range []struct{ name, sym, kind string }{
		{"non_pointer", "sum_args", "uprobearg 1 of sum_args (ptr): argument 1 (a) of sum_args is non-pointer in the binary's DWARF, but the object reads it as ptr"},
		{"char_pointer", "greet", ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			d := t.TempDir()
			os.MkdirAll(filepath.Join(d, "target"), 0o755)
			os.WriteFile(filepath.Join(d, "target", "cfix"), b, 0o755)
			f := filepath.Join(d, "p.rb")
			os.WriteFile(f, []byte(ptrSrc(c.sym, "")), 0o644)
			out, err := Generate(sp, t.TempDir(), f)
			if err != nil {
				t.Fatalf("generate: %v", err)
			}
			err = UprobeBuildCheck(compileAll(t, out), out.Result)
			t.Logf("%v", err)
			if c.kind == "" {
				if err != nil {
					t.Errorf("a const char * argument read as :ptr must pass: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), "p.rb:8:1: rejected SB032") || !strings.Contains(err.Error(), c.kind) {
				t.Errorf("want one SB032 at the declaration (line 8) naming %q", c.kind)
			}
		})
	}
}
