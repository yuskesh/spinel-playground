// Package toolchain は spinelbpf が使う ebpf-compile と spinel の版を照合する (P001 §2 — mojo-bpf-mlir の internal/toolchain を写し、Spinel の照合を足した)。
//
// ebpf-compile: E160 から、compiler と Go の module を 1 つの pin の commit で照合する (go-bpf-mlir E258 H2 / E263 — 前は describe が `go/<module の版>`
// そのものを要求したが、開発の pin の commit ab0db4b40 は release の tag でない)。`ebpf-compile --version` の `bpf-mlir <describe> (commit <sha>)` の行で、
// 次が一致しなければ loud に止める — 照合を飛ばす経路は置かない:
//
//  1. --version の commit が PinnedCompilerCommit (describe は由来の記録だけ — 版の文字列は照合しない)
//  2. describe が `-dirty` で終わらない・`unknown` でない (pin の commit から変えた source の build を拒否)
//  3. spinelbpf の build の時の BPFMLIRGoModule (開発の形は bpf-mlir の Go の module) の版 (runtime/debug.ReadBuildInfo — replace・(devel) は止める) が PinnedModuleVersion
//  4. repo に third_party/bpf-mlir が在るときは、その source の commit (submoduleSource — 開発の形は submodule の HEAD) が --version の commit と同じ
//
// 公開の形 (build tag spinelbpf_public — E161) は 1 の commit が ReleaseCompilerCommit (bpf-mlir ReleaseCompilerVersion の source release)、3 の module が
// go-bpf-mlir の ReleaseGoModuleVersion (bpf-mlir の Go の package を写した release — 手本の go-bpf-mlir は package を自分の tree に写すので
// module を照合しないが、ここは別の module を require するので版を見る)。2 は同じ。4 は submodule の tree の根の SOURCE_VERSION の source_commit
// (公開 bpf-mlir の submodule の HEAD は書き出しの commit で C と別の SHA — E167)。
//
// spinel: `spinel --version` の `(<commit>)` が SpinelCommit (CLAUDE.md の固定の版) の接頭辞で、repo に third_party/spinel が在るときはその HEAD とも一致すること。
package toolchain

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime/debug"
	"strconv"
	"strings"
)

// BPFMLIRGoModule・PinnedCompilerCommit・PinnedModuleVersion・compilerFix・moduleNote は build tag spinelbpf_public の pin の対
// (pin_dev.go — 開発の repo、pin_public.go — 公開の形。E161 — go-bpf-mlir の pin_dev / pin_public の写し)。

// SpinelCommit は固定の Spinel の commit (CLAUDE.md — upstream matz/spinel)。版を上げるときはこの値と submodule を同じ commit で。
const SpinelCommit = "086d514d"

// Verified は照合した値 (生成物の由来の記録に書く)。
type Verified struct {
	Describe  string // --version の describe (由来の記録 — E160 から照合しない)
	Commit    string // --version の commit
	Module    string // spinelbpf の build の bpf-mlir/go の版
	Submodule string // third_party/bpf-mlir の HEAD ("" は submodule が無い)
}

var versionLine = regexp.MustCompile(`(?m)^\s*bpf-mlir (\S+) \(commit (\S+)\)\s*$`)
var spinelLine = regexp.MustCompile(`^spinel \S+ \(([0-9a-f]{7,40})\)`)

// ModuleVersion は build の情報から bpf-mlir/go の版を取る。replace・(devel)・無いは誤り。
func ModuleVersion(bi *debug.BuildInfo) (string, error) {
	if bi == nil {
		return "", errors.New("spinelbpf has no build information (runtime/debug.ReadBuildInfo) — cannot tell which bpf-mlir/go it was built with")
	}
	for _, d := range bi.Deps {
		if d.Path != BPFMLIRGoModule {
			continue
		}
		if d.Replace != nil {
			return "", fmt.Errorf("spinelbpf was built with %s replaced by %s %s — the compiler version cannot be checked against a replaced module (remove the replace directive)", BPFMLIRGoModule, d.Replace.Path, d.Replace.Version)
		}
		if d.Version == "" || d.Version == "(devel)" {
			return "", fmt.Errorf("spinelbpf was built with %s at version %q — the compiler version cannot be checked against an unversioned module", BPFMLIRGoModule, d.Version)
		}
		return d.Version, nil
	}
	return "", fmt.Errorf("spinelbpf's build information has no dependency %s", BPFMLIRGoModule)
}

// Verify は --version の出力・module の版・submodule の commit ("" は無い) を pin と照合する (E160 — 上の 1〜4)。
func Verify(versionOutput, moduleVersion, submoduleCommit string) (Verified, error) {
	fix := compilerFix
	m := versionLine.FindStringSubmatch(versionOutput)
	if m == nil {
		return Verified{}, fmt.Errorf("ebpf-compile --version has no `bpf-mlir <version> (commit <sha>)` line — spinelbpf needs bpf-mlir commit %s; %s", PinnedCompilerCommit, fix)
	}
	v := Verified{Describe: m[1], Commit: m[2], Module: moduleVersion, Submodule: submoduleCommit}
	if v.Commit != PinnedCompilerCommit {
		return v, fmt.Errorf("ebpf-compile is bpf-mlir %s (commit %s), but spinelbpf needs exactly bpf-mlir commit %s; %s", v.Describe, v.Commit, PinnedCompilerCommit, fix)
	}
	if strings.HasSuffix(v.Describe, "-dirty") || v.Describe == "unknown" {
		return v, fmt.Errorf("ebpf-compile is bpf-mlir %q (commit %s), a build from modified or unidentified source: spinelbpf refuses it; %s", v.Describe, v.Commit, fix)
	}
	if moduleVersion != PinnedModuleVersion {
		return v, fmt.Errorf("spinelbpf was built with %s %s, but the pinned version is %s (%s) — rebuild spinelbpf with the go.mod of this repo", BPFMLIRGoModule, moduleVersion, PinnedModuleVersion, moduleNote)
	}
	if submoduleCommit != "" && submoduleCommit != v.Commit {
		return v, fmt.Errorf("ebpf-compile was built from bpf-mlir commit %s but %s %s — rebuild with scripts/setup.sh", v.Commit, submoduleWhat, submoduleCommit)
	}
	return v, nil
}

// headOf は repo/third_party/<name> の HEAD (submodule が無ければ "")。
func headOf(repo, name string) (string, error) {
	if repo == "" {
		return "", nil
	}
	sub := filepath.Join(repo, "third_party", name)
	if _, err := os.Stat(filepath.Join(sub, ".git")); err != nil {
		return "", nil
	}
	out, err := exec.Command("git", "-C", sub, "rev-parse", "HEAD").Output()
	if err != nil {
		return "", fmt.Errorf("reading the commit of %s: %w", sub, err)
	}
	return strings.TrimSpace(string(out)), nil
}

// Check は ebpf-compile の --version を読み、spinelbpf の build の情報と repo の submodule で照合する。
func Check(compiler, repo string) (Verified, error) {
	out, err := exec.Command(compiler, "--version").CombinedOutput()
	if err != nil {
		return Verified{}, fmt.Errorf("running %s --version: %w", compiler, err)
	}
	bi, _ := debug.ReadBuildInfo()
	mod, err := ModuleVersion(bi)
	if err != nil {
		return Verified{}, err
	}
	sub, err := submoduleSource(repo)
	if err != nil {
		return Verified{}, err
	}
	return Verify(string(out), mod, sub)
}

var sourceVersionNumber = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
var sourceCommitHex = regexp.MustCompile(`^[0-9a-f]{40}$`)

// sourceVersionFormat は読める SOURCE_VERSION の形式の版 (公開 bpf-mlir v1.21.0 の書き出しの `format=1`)。
const sourceVersionFormat = "1"

// ParseSourceVersion reads the SOURCE_VERSION at the root of a bpf-mlir source release's tree strictly (E167 — corrected to the real three lines after the bpf-mlir reviewer's review):
// exactly three lines `format=1`, `version=<N.N.N>`, `source_commit=<40 lowercase hex digits>`, in this order (at most one final newline). Anything else is an error (fail closed).
func ParseSourceVersion(b []byte) (version, commit string, err error) {
	s := string(b)
	if strings.ContainsRune(s, '\r') {
		return "", "", errors.New("SOURCE_VERSION has a carriage return")
	}
	lines := strings.Split(strings.TrimSuffix(s, "\n"), "\n")
	if len(lines) != 3 {
		return "", "", fmt.Errorf("SOURCE_VERSION has %d lines, want exactly 3 (format=, version= and source_commit=)", len(lines))
	}
	if lines[0] != "format="+sourceVersionFormat {
		return "", "", fmt.Errorf("SOURCE_VERSION line 1 is %q, want format=%s", lines[0], sourceVersionFormat)
	}
	version, ok := strings.CutPrefix(lines[1], "version=")
	if !ok || !sourceVersionNumber.MatchString(version) {
		return "", "", fmt.Errorf("SOURCE_VERSION line 2 is %q, want version=<major>.<minor>.<patch>", lines[1])
	}
	commit, ok = strings.CutPrefix(lines[2], "source_commit=")
	if !ok || !sourceCommitHex.MatchString(commit) {
		return "", "", fmt.Errorf("SOURCE_VERSION line 3 is %q, want source_commit=<40 lowercase hex digits>", lines[2])
	}
	return version, commit, nil
}

// releaseSource は公開の形の照合 4 の値 (E167): repo/third_party/bpf-mlir/SOURCE_VERSION の source_commit。version は want (`v` を除く) と同じであること。
// submodule が checkout されていない (SOURCE_VERSION も .git も無い) ときは ""、.git が在って SOURCE_VERSION が無いときは誤り。
// tag の無い file に置き、開発の形の gate でも試験する (公開の形の submoduleSource が呼ぶ)。
func releaseSource(repo, want string) (string, error) {
	if repo == "" {
		return "", nil
	}
	sub := filepath.Join(repo, "third_party", "bpf-mlir")
	path := filepath.Join(sub, "SOURCE_VERSION")
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		if _, e := os.Stat(filepath.Join(sub, ".git")); e != nil {
			return "", nil
		}
		return "", fmt.Errorf("%s is checked out but has no SOURCE_VERSION — spinelbpf checks ebpf-compile against the source_commit of the bpf-mlir %s source release", sub, want)
	}
	if err != nil {
		return "", fmt.Errorf("reading %s: %w", path, err)
	}
	v, c, err := ParseSourceVersion(b)
	if err != nil {
		return "", fmt.Errorf("%s: %w", path, err)
	}
	if "v"+v != want {
		return "", fmt.Errorf("%s says version %s, but spinelbpf needs the bpf-mlir %s source release", path, v, want)
	}
	return c, nil
}

// VerifySpinel は spinel --version の出力を固定の commit と submodule の HEAD ("" は無い) で照合する。
func VerifySpinel(versionOutput, submoduleHead string) (string, error) {
	fix := "build Spinel " + SpinelCommit + " (scripts/setup.sh in spinel-bpf-mlir), or point SPINEL at a build of that commit"
	m := spinelLine.FindStringSubmatch(strings.TrimSpace(versionOutput))
	if m == nil {
		return "", fmt.Errorf("spinel --version has no `spinel <version> (<commit>)` line (%q); %s", strings.TrimSpace(versionOutput), fix)
	}
	c := m[1]
	if !strings.HasPrefix(c, SpinelCommit) && !strings.HasPrefix(SpinelCommit, c) {
		return c, fmt.Errorf("spinel is commit %s but spinelbpf is pinned to %s — the frontend reads Spinel's AST and types, whose shape is only checked for that commit; %s", c, SpinelCommit, fix)
	}
	if submoduleHead != "" && !strings.HasPrefix(submoduleHead, c) {
		return c, fmt.Errorf("spinel was built from commit %s but third_party/spinel is at %s — rebuild with scripts/setup.sh", c, submoduleHead)
	}
	return c, nil
}

// CheckSpinel は spinel の --version を照合する。
func CheckSpinel(spinel, repo string) (string, error) {
	out, err := exec.Command(spinel, "--version").CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("running %s --version: %w", spinel, err)
	}
	head, err := headOf(repo, "spinel")
	if err != nil {
		return "", err
	}
	return VerifySpinel(string(out), head)
}

var diagLoc = regexp.MustCompile(`^loc\("([^"]+)":(\d+):(\d+)\): (.*)$`)

// RewriteLocs は ebpf-compile の診断の行 `loc("F":L:C): <msg>` を `F:L:C: ebpf-compile: <msg>` に読み替える (表示だけ — 判定は変えない)。
// 位置は loc の相対の file の名前のまま — frontend の診断・SB021 と同じ形 (E013 のレビューの P3 — 絶対の path は build の directory を漏らす)。
func RewriteLocs(output string) string {
	var b strings.Builder
	for _, line := range strings.Split(strings.TrimRight(output, "\n"), "\n") {
		if m := diagLoc.FindStringSubmatch(line); m != nil && !filepath.IsAbs(m[1]) {
			fmt.Fprintf(&b, "%s:%s:%s: ebpf-compile: %s\n", m[1], m[2], m[3], m[4])
			continue
		}
		b.WriteString(line)
		b.WriteByte('\n')
	}
	return b.String()
}

// CompileLoc は ebpf-compile の warning / note の位置 — loc の相対の file の名前のまま (frontend の診断の位置と同じ形 — E013 のレビュー:
// 絶対の path は build の directory を漏らし再現性を壊す。rc ≠ 0 の RewriteLocs も同じ形)。
type CompileLoc struct {
	File      string
	Line, Col int
}

func (l CompileLoc) String() string { return fmt.Sprintf("%s:%d:%d", l.File, l.Line, l.Col) }

// CompileWarning は ebpf-compile が rc 0 で出した warning 1 つと、続く note (bpf-mlir v0.10.0 E274 — 例: the constant index comes from here)。
type CompileWarning struct {
	Loc   CompileLoc
	Msg   string
	Notes []CompileNote
}

// CompileNote は warning に付く note。
type CompileNote struct {
	Loc CompileLoc
	Msg string
}

// ParseCompileOutput は rc 0 で終わった ebpf-compile の stdout と stderr を読み、warning (と続く note) を返す (P003 §2)。
// 知らない出力は誤り (fail closed — bpf-mlir が新しい種類の出力を足したら気付く): 空でない stdout・loc の無い行・
// warning / note でない行 (error: 等)・warning の前の note・絶対の path の loc。
func ParseCompileOutput(stdout, stderr string) ([]CompileWarning, error) {
	unknown := func(what, line string) error {
		return fmt.Errorf("ebpf-compile exited 0 with %s — a new output shape of ebpf-compile; update spinelbpf's reader: %q", what, line)
	}
	if stdout != "" {
		return nil, unknown("output on stdout", strings.TrimRight(stdout, "\n"))
	}
	var ws []CompileWarning
	if stderr == "" {
		return nil, nil
	}
	for _, line := range strings.Split(strings.TrimSuffix(stderr, "\n"), "\n") {
		m := diagLoc.FindStringSubmatch(line)
		if m == nil || filepath.IsAbs(m[1]) {
			return nil, unknown("a stderr line that is not loc(\"<relative file>\":L:C): warning|note: …", line)
		}
		ln, _ := strconv.Atoi(m[2])
		col, _ := strconv.Atoi(m[3])
		loc := CompileLoc{File: m[1], Line: ln, Col: col}
		switch {
		case strings.HasPrefix(m[4], "warning: "):
			ws = append(ws, CompileWarning{Loc: loc, Msg: strings.TrimPrefix(m[4], "warning: ")})
		case strings.HasPrefix(m[4], "note: "):
			if len(ws) == 0 {
				return nil, unknown("a note before any warning", line)
			}
			w := &ws[len(ws)-1]
			w.Notes = append(w.Notes, CompileNote{Loc: loc, Msg: strings.TrimPrefix(m[4], "note: ")})
		default:
			return nil, unknown("a diagnostic that is neither a warning nor a note", line)
		}
	}
	return ws, nil
}
