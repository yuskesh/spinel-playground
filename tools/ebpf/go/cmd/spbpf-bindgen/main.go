// spbpf-bindgen — 正典 schema から cilium/ebpf 向けの型付き bindings を生成する。
//
//	spbpf-bindgen --schema schema.json --object program.bpf.o --output objects_gen.go
//
// **schema が正典**であり、生成物はその派生である。ELF は go:embed で埋め込む形に
// なるので、生成 Go を使う側は cgo も C ソースも MLIR も要らない。
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"spinel-llvm/tools/ebpf/go/internal/bindgen"
)

func main() {
	schemaPath := flag.String("schema", "", "the canonical schema (JSON)")
	objectPath := flag.String("object", "", "the BPF ELF with BTF to embed")
	outputPath := flag.String("output", "", "the Go file to generate")
	pkg := flag.String("package", "", "package name of the generated Go (default: the output directory's name)")
	flag.Parse()

	if *schemaPath == "" || *objectPath == "" || *outputPath == "" {
		fmt.Fprintln(os.Stderr, "usage: spbpf-bindgen --schema S --object O --output F")
		os.Exit(2)
	}
	name := *pkg
	if name == "" {
		name = filepath.Base(filepath.Dir(mustAbs(*outputPath)))
	}

	schema, err := os.ReadFile(*schemaPath)
	if err != nil {
		die("cannot read the schema: %v", err)
	}
	// go:embed は生成 Go からの相対パスでなければならない。
	rel, err := filepath.Rel(filepath.Dir(mustAbs(*outputPath)), mustAbs(*objectPath))
	if err != nil {
		die("cannot make the ELF's relative path: %v", err)
	}
	if _, err := os.Stat(*objectPath); err != nil {
		die("the ELF is missing (run spbpf-compile first): %v", err)
	}

	out, err := bindgen.Generate(bindgen.Input{
		Package: name, SchemaJSON: schema, ObjectPath: rel,
	})
	if err != nil {
		die("%v", err)
	}
	if err := os.WriteFile(*outputPath, out, 0o644); err != nil {
		die("cannot write: %v", err)
	}
}

func mustAbs(p string) string {
	a, err := filepath.Abs(p)
	if err != nil {
		die("%v", err)
	}
	return a
}

func die(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "spbpf-bindgen: "+format+"\n", a...)
	os.Exit(1)
}
