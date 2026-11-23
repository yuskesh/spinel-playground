// Package version は spinel-bpf-mlir の版の文字列と依存の pin (P022 E090)。
//
// Version は release の版 (v0.x — 互換の約束なし、docs/release.md)。次の release まで変えない (P022 のレビューの (e) — 生成物の `.mlir` の版の行が
// 揺れないように、release の間の build は `--version` の commit で区別する)。BML・Spinel は submodule の pin の commit の先頭 (TestVersionPins が
// gitlink と照らす — pin を上げて定数を忘れると落ちる)。bpf-mlir の版は go.mod の require (build の情報から読む)。
package version

import (
	"fmt"
	"runtime/debug"
	"strings"
)

const (
	Version = "v0.9.1"
	BML     = "41ec56f"
	Spinel  = "086d514d"
)

// BpfMLIRModule (bpf-mlir の Go の module — go.mod の require) と bpfMLIRLine は build tag spinelbpf_public の対 (version_dev.go・version_public.go — E161)。

// MLIRLine は生成物の `.mlir` の 2 行目 (版だけ — commit は入れない: 生成物の再現は版の中で保つ)。
func MLIRLine() string { return "// spinel-bpf-mlir " + Version + "\n" }

// Commit は build の vcs の stamp (`<12 桁>` と汚れていれば `+dirty`)。stamp が無ければ "unknown" (黙って空にしない)。
func Commit(bi *debug.BuildInfo) string {
	if bi == nil {
		return "unknown"
	}
	rev, dirty := "", false
	for _, s := range bi.Settings {
		switch s.Key {
		case "vcs.revision":
			rev = s.Value
		case "vcs.modified":
			dirty = s.Value == "true"
		}
	}
	if rev == "" {
		return "unknown"
	}
	if len(rev) > 12 {
		rev = rev[:12]
	}
	if dirty {
		rev += "+dirty"
	}
	return rev
}

// BpfMLIR は go.mod の require の bpf-mlir の版 (replace の時も require の版 — replace の先は注釈に: 中身の版は分からない。版の照合の正典は
// ebpf-compile の --version と bml の header の照合)。
func BpfMLIR(bi *debug.BuildInfo) string {
	if bi != nil {
		for _, d := range bi.Deps {
			if d.Path != BpfMLIRModule {
				continue
			}
			v := bpfMLIRLine(d.Version)
			if d.Replace != nil {
				r := d.Replace.Path
				if d.Replace.Version != "" {
					r += "@" + d.Replace.Version
				}
				v += "; replaced by " + r
			}
			return v + ")"
		}
	}
	return "unknown (no build information)"
}

// Text は `spinelbpf --version` の出力 (ec は ebpf-compile の --version の 1 行目、無ければ "")。
func Text(ec string) string {
	bi, _ := debug.ReadBuildInfo()
	var b strings.Builder
	fmt.Fprintf(&b, "spinel-bpf-mlir %s (commit %s)\n", Version, Commit(bi))
	fmt.Fprintf(&b, "bpf-mlir %s\n", BpfMLIR(bi))
	fmt.Fprintf(&b, "bml %s\n", bmlLine())
	fmt.Fprintf(&b, "spinel %s\n", Spinel)
	if ec == "" {
		ec = "not found"
	}
	fmt.Fprintf(&b, "ebpf-compile: %s\n", ec)
	return b.String()
}
