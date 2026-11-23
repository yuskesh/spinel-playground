package frontend

import (
	"bytes"
	"crypto/sha256"
	"debug/elf"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// E156 の試験 (P029 §2 段 3): uprobe の target の正規の絶対の path (SB008 を開く) と、開いた形の build の時の照合。

// uprobeBuildStop は testdata/uprobe の src の from を to に替えた source (target/cfix を同じ dir に写す) を build の時の照合まで走らせ、
// 宣言の行の 1 つの SB032 の文を返す (他の結果は t.Errorf)。
func uprobeBuildStop(t *testing.T, sp Spinel, src, from, to string, line int) string {
	t.Helper()
	text, _ := os.ReadFile(filepath.Join("testdata", "uprobe", src))
	if !strings.Contains(string(text), from) {
		t.Fatalf("%s lacks %q", src, from)
	}
	d := t.TempDir()
	os.MkdirAll(filepath.Join(d, "target"), 0o755)
	b, _ := os.ReadFile(filepath.Join("testdata", "uprobe", "target", "cfix"))
	os.WriteFile(filepath.Join(d, "target", "cfix"), b, 0o755)
	f := filepath.Join(d, src)
	os.WriteFile(f, []byte(strings.Replace(string(text), from, to, 1)), 0o644)
	out, err := Generate(sp, t.TempDir(), f)
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	err = UprobeBuildCheck(compileAll(t, out), out.Result)
	var e *Error
	if !errors.As(err, &e) || len(e.Diags) != 1 || e.Diags[0].Code != SB032UprobeTarget || e.Diags[0].Pos.Line != line {
		t.Errorf("want one SB032 at the declaration (line %d), got %v", line, err)
		return ""
	}
	return e.Diags[0].Msg
}

// TestUprobeAbsBuildMismatch は E156 の H3 と追補 1: 前は SB008 だった絶対の path の 2 つの負の例の元の形 (neg_abs_path・neg_uret_abs_path) は
// frontend を通り、build の時の照合が無い symbol (uprobe_symbol) の SB032 で止める。
func TestUprobeAbsBuildMismatch(t *testing.T) {
	sp := testSpinel(t)
	for _, c := range []struct {
		name, src, from, to, kind string
		line                      int
	}{
		{"uprobe", "up_ints.rb", `"target/cfix", "sum_args"`, `"/usr/bin/true", "greet"`, "uprobe_symbol greet", 11},
		{"uretprobe", "uret_ints.rb", `"target/cfix", "sum_args"`, `"/bin/true", "main"`, "uprobe_symbol main", 13},
	} {
		t.Run(c.name, func(t *testing.T) {
			msg := uprobeBuildStop(t, sp, c.src, c.from, c.to, c.line)
			t.Log(msg)
			if msg != "" && !strings.Contains(msg, c.kind) {
				t.Errorf("want %q in %s", c.kind, msg)
			}
		})
	}
}

// TestUprobeLibcPositive は E156 の H2: 正の例 up_libc_gai (target は system の libc の絶対の path — 本体に DWARF が無い) が生成でき bpf-mlir の道具を通り、
// build の時の照合が分けた DWARF (debugRoot の /usr/lib/debug/.build-id — host の libc6-dbg) で Unmet 0。schema の binary_sha256 は libc の SHA-256、
// path の文字列は .mlir・schema・maps.json・ELF に無い、ELF の requirements に strptr の uprobearg。
func TestUprobeLibcPositive(t *testing.T) {
	sp := testSpinel(t)
	b, err := os.ReadFile("/lib/x86_64-linux-gnu/libc.so.6")
	if err != nil {
		t.Fatal(err)
	}
	want := fmt.Sprintf("%x", sha256.Sum256(b))
	out, err := Generate(sp, t.TempDir(), filepath.Join("testdata", "uprobe", "up_libc_gai.rb"))
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	elf := compileAll(t, out)
	if err := UprobeBuildCheck(elf, out.Result); err != nil {
		t.Errorf("the build-time check refused the libc program (is libc6-dbg installed for this libc6? the check reads %s/.build-id): %v", debugRoot, err)
	}
	if !strings.Contains(string(out.Schema), `"binary_sha256": "`+want+`"`) {
		t.Errorf("schema binary_sha256 is not the host libc's %s", want)
	}
	for what, x := range map[string][]byte{"mlir": []byte(out.MLIR), "schema": out.Schema, "maps": out.Maps, "elf": elf} {
		if bytes.Contains(x, []byte("libc.so")) || bytes.Contains(x, []byte("x86_64-linux-gnu")) {
			t.Errorf("the %s contains the target path", what)
		}
	}
	if !bytes.Contains(elf, []byte("uprobearg\ton_gai\t1\tstrptr\n")) || !bytes.Contains(elf, []byte(want)) {
		t.Errorf("the ELF requirements lack the strptr uprobearg row or the libc hash")
	}
}

// buildIDOf は ELF の GNU build ID (.note.gnu.build-id の desc)。
func buildIDOf(t *testing.T, path string) []byte {
	t.Helper()
	f, err := elf.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	s := f.Section(".note.gnu.build-id")
	if s == nil {
		t.Fatalf("%s has no GNU build ID", path)
	}
	d, err := s.Data()
	if err != nil || len(d) < 16 {
		t.Fatalf("%s: build ID note: %v", path, err)
	}
	nameSz, descSz := binary.LittleEndian.Uint32(d[0:]), binary.LittleEndian.Uint32(d[4:])
	off := 12 + (nameSz+3)&^3
	return d[off : off+descSz]
}

// splitFixture は testdata/uprobe/target の src を gcc の -g と build ID 付きで dir に build し (試験の中だけの一時の file — 再現の fixture でない)、分けた DWARF (only-keep-debug) を out.debug に、本体の DWARF を消す。
func splitFixture(t *testing.T, dir, src, out string) string {
	t.Helper()
	p := filepath.Join(dir, out)
	for _, c := range [][]string{
		{"gcc", "-g", "-O1", "-fno-inline-functions", "-Wl,--build-id=sha1", "-o", p, filepath.Join("testdata", "uprobe", "target", src)},
		{"objcopy", "--only-keep-debug", p, p + ".debug"},
		{"strip", "--strip-debug", p},
	} {
		if o, err := exec.Command(c[0], c[1:]...).CombinedOutput(); err != nil {
			t.Fatalf("%v: %v\n%s", c, err, o)
		}
	}
	return p
}

// TestUprobeSplitDebugBuild は E156 の H3 の分けた file の行: 自作の C (cfix.c — DWARF を消した本体 A) の uprobe を、一時の debugRoot で
// (ok) A の build ID の path に A の分けた file → 照合の Unmet 0 (対照)、(badid) 同じ path に別の binary (gfix.c — B) の分けた file → SB032
// uprobe_debug_build_id、(missing) 空の root → SB032 uprobearg_unknown (分けた file が無いのは不一致ではない)。
func TestUprobeSplitDebugBuild(t *testing.T) {
	sp := testSpinel(t)
	d := t.TempDir()
	a := splitFixture(t, d, "cfix.c", "a")
	bdir := t.TempDir()
	b := splitFixture(t, bdir, "gfix.c", "b")
	id := fmt.Sprintf("%x", buildIDOf(t, a))
	old := debugRoot
	t.Cleanup(func() { debugRoot = old })
	for _, c := range []struct{ name, debug, kind string }{
		{"ok", a + ".debug", ""},
		{"badid", b + ".debug", "uprobe_debug_build_id sum_args"},
		{"missing", "", "uprobearg_unknown 1 of sum_args"},
	} {
		t.Run(c.name, func(t *testing.T) {
			debugRoot = t.TempDir()
			if c.debug != "" {
				x, _ := os.ReadFile(c.debug)
				os.MkdirAll(filepath.Join(debugRoot, ".build-id", id[:2]), 0o755)
				os.WriteFile(filepath.Join(debugRoot, ".build-id", id[:2], id[2:]+".debug"), x, 0o644)
			}
			if c.kind == "" {
				text, _ := os.ReadFile(filepath.Join("testdata", "uprobe", "up_ints.rb"))
				f := filepath.Join(t.TempDir(), "up_ints.rb")
				os.WriteFile(f, []byte(strings.Replace(string(text), `"target/cfix"`, `"`+a+`"`, 1)), 0o644)
				out, err := Generate(sp, t.TempDir(), f)
				if err != nil {
					t.Fatalf("generate: %v", err)
				}
				if err := UprobeBuildCheck(compileAll(t, out), out.Result); err != nil {
					t.Errorf("the matching separate DWARF was refused: %v", err)
				}
				return
			}
			msg := uprobeBuildStop(t, sp, "up_ints.rb", `"target/cfix"`, `"`+a+`"`, 11)
			t.Log(msg)
			if msg != "" && !strings.Contains(msg, c.kind) {
				t.Errorf("want %q in %s", c.kind, msg)
			}
		})
	}
}
