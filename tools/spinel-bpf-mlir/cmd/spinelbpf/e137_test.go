package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// E137's test (P027): checks the bcc tools' tracepoint declarations without root (the bpf-mlir coordinator's request i779 — so that a tracefs mismatch does not waste a root run).

// tpFormatField は tracefs の format の 1 つの field (名前・offset・size・signed・配列か)。
type tpFormatField struct {
	offset, size int
	signed, array bool
	stars        int // P028 E147: decl の `*` の数 (char * の深度 — user_str は 1)
	n            int // P029 E153: 配列の要素の数 (`[N]` — 配列でなければ 0)
}

var tpFormatLine = regexp.MustCompile(`^\s*field:(.+);\s*offset:(\d+);\s*size:(\d+);\s*signed:(\d);`)

// readTpFormat は testdata/tracefs-7.1.8/<cat>__<event>.format (host 7.1.8 の root で 1 回読んで記録した — E137) の field の表。
func readTpFormat(t *testing.T, target string) map[string]tpFormatField {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "tracefs-7.1.8", strings.Replace(target, "/", "__", 1)+".format"))
	if err != nil {
		t.Fatalf("%s: no recorded tracefs format (%v) — read it once as root into testdata/tracefs-7.1.8", target, err)
	}
	fs := map[string]tpFormatField{}
	for _, l := range strings.Split(string(b), "\n") {
		m := tpFormatLine.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		decl := strings.TrimSpace(m[1])
		arr := strings.Contains(decl, "[")
		n := 0
		if i := strings.Index(decl, "["); i >= 0 {
			n, _ = strconv.Atoi(strings.TrimSuffix(decl[i+1:], "]"))
			decl = decl[:i]
		}
		ws := strings.Fields(decl)
		name := strings.TrimLeft(ws[len(ws)-1], "*")
		off, _ := strconv.Atoi(m[2])
		size, _ := strconv.Atoi(m[3])
		fs[name] = tpFormatField{off, size, m[4] == "1", arr, strings.Count(decl, "*"), n}
	}
	return fs
}

// TestBccTracepointFormats は E137 の手順 0: examples/bcc の各 tool の schema の tracepoint の program の fields が、記録した tracefs の format と (P028 E147: :user_str の field は char * の深度 1 と)
// 名前・offset・幅・符号で一致し、配列の field を整数として宣言していない (load の前の照合は配列かを見ない — i743 の条件 (a))。
func TestBccTracepointFormats(t *testing.T) {
	parallel(t)
	type field struct {
		Name   string `json:"name"`
		Offset int    `json:"offset"`
		Type   struct {
			Kind   string `json:"kind"` // P028 E147: user_str は char * (深度 1) と照らす
			Elem   string `json:"elem"` // P029 E153: 固定 byte の配列 {kind: array, elem: u8|i8, n: N}
			N      int    `json:"n"`
			Bits   int  `json:"bits"`
			Signed bool `json:"signed"`
		} `json:"type"`
	}
	type prog struct {
		Name         string  `json:"name"`
		Kind         string  `json:"kind"`
		AttachTarget string  `json:"attach_target"`
		Fields       []field `json:"fields"`
	}
	checked := 0
	var reinterpret []string // P029 E153 (R005 の review): 記録の format が配列なのに整数と宣言した field — 失敗にせず名指す (bpf-mlir と同じ境界)
	for _, name := range bccToolNames(t) {
		b, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "bcc", name, name+".schema.json"))
		if err != nil {
			t.Fatal(err)
		}
		var doc struct {
			Core struct {
				Programs []prog `json:"programs"`
			} `json:"core"`
		}
		if err := strictUnmarshal(b, &doc); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		for _, p := range doc.Core.Programs {
			if p.Kind != "tracepoint" {
				continue
			}
			fs := readTpFormat(t, p.AttachTarget)
			for _, f := range p.Fields {
				g, ok := fs[f.Name]
				switch {
				case !ok:
					t.Errorf("%s %s: field %s is not in the %s format", name, p.Name, f.Name, p.AttachTarget)
				case f.Type.Kind == "user_str": // P028 E147: char * (深度 1)・8 byte・offset が一致、配列でない
					if g.array || g.stars != 1 || g.size != 8 || g.offset != f.Offset {
						t.Errorf("%s %s: field %s is declared :user_str (offset %d) but the %s format has offset %d size %d pointer depth %d array %v — want a char * (depth 1, 8 bytes)", name, p.Name, f.Name, f.Offset, p.AttachTarget, g.offset, g.size, g.stars, g.array)
					}
				case f.Type.Kind == "array": // P029 E153: 1 次元の byte の配列で要素の数・offset・符号が一致
					if !g.array || g.n != f.Type.N || g.size != f.Type.N || g.offset != f.Offset || g.signed != (f.Type.Elem == "i8") || g.stars != 0 {
						t.Errorf("%s %s: field %s is declared [:%s, %d] at offset %d but the %s format has offset %d size %d array %v [%d] signed %v", name, p.Name, f.Name, f.Type.Elem, f.Type.N, f.Offset, p.AttachTarget, g.offset, g.size, g.array, g.n, g.signed)
					}
				case g.array: // E137 i743 (a) は失敗だった — R005 の review で「再解釈」の一覧に (失敗にしない)
					reinterpret = append(reinterpret, fmt.Sprintf("%s %s %s (%s [%d] declared as an integer)", name, p.Name, f.Name, p.AttachTarget, g.n))
				case g.offset != f.Offset || g.size*8 != f.Type.Bits || g.signed != f.Type.Signed:
					t.Errorf("%s %s: field %s is offset %d size %d signed %v in the %s format, the program declares offset %d bits %d signed %v",
						name, p.Name, f.Name, g.offset, g.size, g.signed, p.AttachTarget, f.Offset, f.Type.Bits, f.Type.Signed)
				}
				checked++
			}
		}
	}
	t.Logf("checked %d tracepoint field declarations", checked)
	t.Logf("reinterpretations (array fields declared as integers): %d %v", len(reinterpret), reinterpret)
	if checked == 0 {
		t.Error("no tracepoint field was checked")
	}
}

// E137 の H4 / H5。
func TestBccSelftestSyscount(t *testing.T)  { bccSelftest(t, "bcc/syscount") }
func TestBccSelftestVfsstat(t *testing.T)   { bccSelftest(t, "bcc/vfsstat") }
func TestBccSelftestFunccount(t *testing.T) { bccSelftest(t, "bcc/funccount") }
func TestBccSelftestArgdist(t *testing.T)   { bccSelftest(t, "bcc/argdist") }
func TestBccSelftestCachestat(t *testing.T) { bccSelftest(t, "bcc/cachestat") }
