package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/yuskesh/go-bpf-mlir/requirements"
)

// C の loader (bpf-mlir-loader — bml) の archive と版の照合 (P010 E041)。

// bmlArchives は bml の archive の link の順 (bml E007 — shim が先、libbml の後に libbpf・libelf・libz)。
var bmlArchives = []string{"libbml_spinel.a", "libbml.a", "libbpf.a", "libelf.a", "libz.a"}

// versionSet は loader と frontend の版の組 — spinel の bpf-mlir と bml の bpf-mlir が同じで、判定の版と requirements の形式の上限が同じでないといけない
// (食い違うと load の照合が生成物の requirements と違う規則で判定する — build を止める、P010 のレビュー)。
type versionSet struct {
	BpfMlirCommit string
	PolicyVersion int
	MaxFormat     int
}

// spinelVersions は spinel の側 (superproject の index の third_party/bpf-mlir の gitlink — submodule を checkout していない clone でも読める、stage した pointer を見る — と Go の requirements の定数)。
func spinelVersions(cfg Config) (versionSet, error) {
	c, err := pinnedCommit(cfg, "bpf-mlir")
	if err != nil {
		return versionSet{}, err
	}
	return versionSet{c, requirements.PolicyVersion, requirements.MaxFormatVersion}, nil
}

// Spinel Extended: neither bpf-mlir gitlink exists here (spinel-bpf-mlir's
// third_party/bpf-mlir submodule and bml's are not imported), so the two
// commits come from third_party/PINS, which records both sources' gitlinks.
func pinnedCommit(cfg Config, name string) (string, error) {
	p := filepath.Join(cfg.Repo, "third_party", "PINS")
	b, err := os.ReadFile(p)
	if err != nil {
		return "", fmt.Errorf("reading %s: %v", p, err)
	}
	for _, l := range strings.Split(string(b), "\n") {
		if f := strings.Split(l, "\t"); len(f) == 2 && f[0] == name && len(f[1]) == 40 {
			return f[1], nil
		}
	}
	return "", fmt.Errorf("%s names no commit for %s", p, name)
}

var defineRe = func(name string) *regexp.Regexp { return regexp.MustCompile(`(?m)^#define ` + name + ` +([0-9]+)`) }

// bmlVersions は bml の側 (submodule の tree の third_party/bpf-mlir の gitlink と C の定数 — bml の bpf-mlir は checkout しない)。
func bmlVersions(cfg Config) (versionSet, error) {
	bml := filepath.Join(cfg.Repo, "third_party", "bpf-mlir-loader")
	c, err := pinnedCommit(cfg, "bpf-mlir-loader/bpf-mlir")
	if err != nil {
		return versionSet{}, err
	}
	num := func(file, name string) (int, error) {
		b, err := os.ReadFile(filepath.Join(bml, file))
		if err != nil {
			return 0, err
		}
		m := defineRe(name).FindSubmatch(b)
		if m == nil {
			return 0, fmt.Errorf("%s has no #define %s", file, name)
		}
		return strconv.Atoi(string(m[1]))
	}
	p, err := num("src/req/check.h", "BML_POLICY_VERSION")
	if err != nil {
		return versionSet{}, err
	}
	mf, err := num("src/req/req.h", "BML_MAX_FORMAT_VERSION")
	if err != nil {
		return versionSet{}, err
	}
	return versionSet{c, p, mf}, nil
}

// compareVersions は 2 つの組の食い違いを名指しで返す (無ければ nil)。
func compareVersions(sp, bml versionSet) error {
	var bad []string
	if sp.BpfMlirCommit != bml.BpfMlirCommit {
		bad = append(bad, fmt.Sprintf("bpf-mlir commit: spinel %s, bpf-mlir-loader %s", sp.BpfMlirCommit, bml.BpfMlirCommit))
	}
	if sp.PolicyVersion != bml.PolicyVersion {
		bad = append(bad, fmt.Sprintf("judgement (policy) version: spinel's bpf-mlir %d, bpf-mlir-loader %d", sp.PolicyVersion, bml.PolicyVersion))
	}
	if sp.MaxFormat != bml.MaxFormat {
		bad = append(bad, fmt.Sprintf("requirements format maximum: spinel's bpf-mlir %d, bpf-mlir-loader %d", sp.MaxFormat, bml.MaxFormat))
	}
	if len(bad) > 0 {
		return fmt.Errorf("the C loader and the frontend disagree — raise both pins together: %s", strings.Join(bad, "; "))
	}
	return nil
}

func checkBMLVersions(cfg Config) error {
	sp, err := spinelVersions(cfg)
	if err != nil {
		return err
	}
	b, err := bmlVersions(cfg)
	if err != nil {
		return err
	}
	return compareVersions(sp, b)
}
