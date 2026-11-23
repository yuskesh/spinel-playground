package bindgen_test

import (
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"spinel-llvm/tools/ebpf/go/internal/bindgen"
)

// golden: schema から生成する Go が期待どおりであること。
//
// **ここが E432 の穴に対する答え**: 手で写した Go の struct は C の内部 padding を
// 落として静かにずれる。生成側は schema の offset を正典にして padding を明示し、
// decoder も offset で読む。
func TestGenerate(t *testing.T) {
	schema, err := os.ReadFile(filepath.Join("testdata", "schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	got, err := bindgen.Generate(bindgen.Input{
		Package:    "xdpcounter",
		SchemaJSON: schema,
		ObjectPath: "xdp_counter.bpf.o",
	})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}

	golden := filepath.Join("testdata", "objects_gen.go.golden")
	if os.Getenv("UPDATE_GOLDEN") != "" {
		if err := os.WriteFile(golden, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("golden を読めない (UPDATE_GOLDEN=1 で作る): %v", err)
	}
	if string(got) != string(want) {
		t.Errorf("生成 Go が golden と違う\n--- got ---\n%s", got)
	}

	// 生成物に **cgo / C ソース依存が無い**こと (P013 Global Constraints)。
	// 文字列一致だと自分のコメント文言を誤検出するので、**import を構文解析して**見る。
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "objects_gen.go", got, parser.ImportsOnly)
	if err != nil {
		t.Fatalf("生成 Go が parse できない: %v", err)
	}
	allowed := map[string]bool{
		"bytes": true, "embed": true, "encoding/binary": true, "fmt": true,
		"github.com/cilium/ebpf": true,
	}
	for _, imp := range f.Imports {
		path := strings.Trim(imp.Path.Value, `"`)
		if path == "C" {
			t.Error("生成 Go が cgo を引いている")
		}
		if !allowed[path] {
			t.Errorf("生成 Go が想定外の package を引いている: %q", path)
		}
	}
	if strings.Contains(string(got), "#include") {
		t.Error("生成 Go に C の #include が混ざっている")
	}
}

// padding が入り、schema の offset どおりになること。
func TestGeneratePadding(t *testing.T) {
	schema, err := os.ReadFile(filepath.Join("testdata", "schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	got, err := bindgen.Generate(bindgen.Input{
		Package: "xdpcounter", SchemaJSON: schema, ObjectPath: "x.o",
	})
	if err != nil {
		t.Fatal(err)
	}
	s := string(got)
	// event は pid@32 の次が duration_ns@40 なので 4 バイトの穴があく。
	if !strings.Contains(s, "_pad") {
		t.Error("padding が入っていない — Go の詰め方に任せると E432 の穴を再発する")
	}
}

// **合成 schema ではなく E434 の実契約**で生成し、Go として parse できること。
// 実物には `<unit>_dns_events` のような、そのままでは識別子にできない symbol が
// 入っている (これを踏んだ)。
func TestGenerateFromRealContract(t *testing.T) {
	schema, err := os.ReadFile(filepath.Join("testdata", "e434-converted.json"))
	if err != nil {
		t.Skipf("E434 の変換済み schema が無い: %v", err)
	}
	got, err := bindgen.Generate(bindgen.Input{
		Package: "e434", SchemaJSON: schema, ObjectPath: "e434.bpf.o",
	})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	fset := token.NewFileSet()
	if _, err := parser.ParseFile(fset, "objects_gen.go", got, 0); err != nil {
		t.Fatalf("実契約から生成した Go が parse できない: %v", err)
	}
	s := string(got)
	// E432 が測った padding の穴が実物でも入っていること。
	// dns_event は raw@36..100 の次が cgid@104 なので 4 バイトの穴があく。
	if !strings.Contains(s, "type DnsEvent struct") {
		t.Error("DnsEvent が生成されていない")
	}
	if !strings.Contains(s, "_pad") {
		t.Error("実契約でも padding が入っていない")
	}
	// 可変長 record は min_size で下限検査すること。
	if !strings.Contains(s, "len(b) < 120") {
		t.Error("dns_event の可変長下限 (min_size=120) が decoder に入っていない")
	}
}
