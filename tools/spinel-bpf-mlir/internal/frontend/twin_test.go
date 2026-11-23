package frontend

import (
	"os"
	"path/filepath"
	"testing"
)

// TestNativeTwinText は twin の text の形 (行を変えない・harness) を確かめ、TWIN_OUT が在ればそこに書く (E005 の手順の確認用)。
func TestNativeTwinText(t *testing.T) {
	src := filepath.Join(repoRoot(t), "examples", "xdpcount", "xdpcount.rb")
	text, _ := os.ReadFile(src)
	res, err := Analyze(testSpinel(t), t.TempDir(), src, string(text))
	if err != nil || res.Diags.Blocking() {
		t.Fatal(err, res.Diags)
	}
	tw, err := NativeTwin(string(text), res)
	if err != nil {
		t.Fatal(err)
	}
	if o := os.Getenv("TWIN_OUT"); o != "" {
		os.WriteFile(o, []byte(tw), 0o644)
	}
	t.Log("\n" + tw)
}
