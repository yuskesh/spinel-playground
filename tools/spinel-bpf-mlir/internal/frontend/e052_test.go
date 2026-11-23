package frontend

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// TestEBPFOnlyStatic は E052 の H1 (E051 のレビューの P3): ruby/lib/bpf.rb で `BPF.ebpf_only("NAME")` を呼ぶ全ての API (eBPF の側だけ — user の側で
// 呼べば実行の時に raise) が、user の側の静的な検査 (checkUserSideAPI の libCallees ∪ ebpfOnlyHelpers) に在る。足した API が漏れれば落ちる。
func TestEBPFOnlyStatic(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "ruby", "lib", "bpf.rb"))
	if err != nil {
		t.Fatal(err)
	}
	var missing []string
	seen := map[string]bool{}
	for _, m := range regexp.MustCompile(`ebpf_only\("([^"]+)"\)`).FindAllStringSubmatch(string(b), -1) {
		name := strings.TrimPrefix(m[1], "BPF::") // 実行の文の名前 (BPF::MapRef#load) → codegen の callee (MapRef#load)。特異 method は BPF.x のまま
		if seen[name] {
			continue
		}
		seen[name] = true
		if !libCallees[name] && !ebpfOnlyHelpers[name] {
			missing = append(missing, name)
		}
	}
	sort.Strings(missing)
	if len(seen) < 50 || len(missing) > 0 {
		t.Fatalf("%d eBPF-only names in bpf.rb; not rejected statically on the user side: %v", len(seen), missing)
	}
}
