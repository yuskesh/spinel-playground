// Command spinelbpf は 1 つの Ruby (Spinel) の program の eBPF の側を bpf-mlir で ELF にする (P001 §2)。
//
//	spinelbpf build [--line-info=auto|off] [--emit=domain-graph] [--seam-emit E --seam-inspect I] [-o exe] x.rb
//
// --seam-emit / --seam-inspect (P029 E152 — opt-in): Go の frontend の代わりに spinel-mlir の consumer の出力 (E dir の 5 file と
// I dir の domain と inspection の manifest) を読む。manifest で x.rb の sha256・bpf-mlir の pin・出力の sha256 を照らす。
// x.rb の directory に x.mlir・x.schema.json・x.maps.json・x.domain.json・x.bpf.o・x_embed.S・x_embed.o を書く。
// -o で、利用者の program・C の loader の archive (bml)・埋め込みの object を 1 つの実行 file に link し、NEEDED を packaging/needed.allow と照合する (E004)。
// ebpf-compile の系が無いときは、生成し直した .mlir・schema・maps.json が commit 済みの物と同じ場合だけ commit 済みの ELF を使う。
//
// 環境変数: SPINEL (既定 <repo>/third_party/spinel/bin/spinel)、EBPF_COMPILE (既定 <repo>/build/bpf-mlir/bin/ebpf-compile — ebpf-schema-check は同じ directory)、
// LLVM_PREFIX (既定 /opt/llvm-23.1.1 — clang)、SPINELBPF_LOADER_LIBS (既定 <repo>/build/bml/lib — C の loader の archive)。<repo> は spinelbpf の source の repo (SPINELBPF_ROOT で上書き)。PATH は探さない。
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/version"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func usage(w io.Writer) {
	fmt.Fprintln(w, "usage: spinelbpf build [--line-info=auto|off] [--emit=domain-graph] [--seam-emit E --seam-inspect I] [-o exe] x.rb")
	fmt.Fprintln(w, "       spinelbpf --version")
}

// ecVersion は ebpf-compile の --version の bpf-mlir の行 (無い・走らない時は "")。
func ecVersion() string {
	cfg, err := defaultConfig()
	if err != nil {
		return ""
	}
	o, err := exec.Command(cfg.EbpfCompile, "--version").Output()
	if err != nil {
		return ""
	}
	for _, l := range strings.Split(string(o), "\n") { // LLVM の行の後の `bpf-mlir <版> (commit …)`
		if strings.HasPrefix(l, "bpf-mlir ") {
			return strings.TrimSpace(l)
		}
	}
	return ""
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 1 && (args[0] == "--version" || args[0] == "version") { // P022 E090
		fmt.Fprint(stdout, version.Text(ecVersion()))
		return 0
	}
	if len(args) == 0 || args[0] != "build" {
		usage(stderr)
		return 2
	}
	fs := flag.NewFlagSet("build", flag.ContinueOnError)
	fs.SetOutput(stderr)
	lineInfo := fs.String("line-info", "auto", "ebpf-compile --line-info (auto | off)")
	emit := fs.String("emit", "", "also print a stage artefact to stdout: domain-graph")
	out := fs.String("o", "", "link the executable (the program + the loader + the embedded ELF)")
	seamEmit := fs.String("seam-emit", "", "read the eBPF side from spinel-mlir's consumer output: its emit dir (with --seam-inspect)")
	seamInspect := fs.String("seam-inspect", "", "the consumer's inspection dir (domain and inspect-manifest — with --seam-emit)")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	seamSet := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { seamSet[f.Name] = true })
	if seamSet["seam-emit"] != seamSet["seam-inspect"] || (seamSet["seam-emit"] && (*seamEmit == "" || *seamInspect == "")) {
		fmt.Fprintln(stderr, "spinelbpf: --seam-emit and --seam-inspect go together, each with a directory")
		return 2
	}
	if fs.NArg() != 1 {
		usage(stderr)
		return 2
	}
	if *lineInfo != "auto" && *lineInfo != "off" {
		fmt.Fprintf(stderr, "spinelbpf: --line-info must be auto or off, got %q\n", *lineInfo)
		return 2
	}
	if *emit != "" && *emit != "domain-graph" {
		fmt.Fprintf(stderr, "spinelbpf: --emit must be domain-graph, got %q\n", *emit)
		return 2
	}
	cfg, err := defaultConfig()
	if err != nil {
		fmt.Fprintln(stderr, "spinelbpf:", err)
		return 1
	}
	cfg.LineInfo = *lineInfo
	cfg.SeamEmit, cfg.SeamInspect = *seamEmit, *seamInspect
	r, err := Build(cfg, fs.Arg(0))
	if r != nil && *emit == "domain-graph" && r.Output != nil {
		stdout.Write(r.Output.Domain)
	}
	if err != nil {
		var fe *frontend.Error
		if errors.As(err, &fe) {
			fmt.Fprintln(stderr, fe.Error())
		} else {
			fmt.Fprintln(stderr, "spinelbpf:", err)
		}
		return 1
	}
	for _, d := range r.Output.Result.Diags.Sorted() {
		if d.Verdict == frontend.Conditional {
			fmt.Fprintln(stderr, "spinelbpf: warning:", d)
		}
	}
	for _, f := range r.Files {
		fmt.Fprintln(stderr, "spinelbpf: wrote", f)
	}
	if r.Reused {
		fmt.Fprintln(stderr, "spinelbpf: ebpf-compile is not available — using the committed ELF and embedding (the regenerated .mlir / schema / maps.json are identical)")
	}
	if *out != "" {
		if err := Link(cfg, fs.Arg(0), *out); err != nil {
			fmt.Fprintln(stderr, "spinelbpf:", err)
			return 1
		}
		fmt.Fprintln(stderr, "spinelbpf: linked", *out)
	}
	return 0
}
