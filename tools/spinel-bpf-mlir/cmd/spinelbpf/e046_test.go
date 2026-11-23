package main

import (
	"strings"
	"testing"
)

// E171: 公開の tree (E の番号の file を出さない) で TestTableDifferential (e010_test.go) が無く成り立たないので verified_test.go から動かした (本体は不変)。

// TestVerifiedKeyClosure は E046 の仕組みの単体: 閉包が試験自身と共有の helper と testdata を拾い、関係の無い試験の file を拾わない。
func TestVerifiedKeyClosure(t *testing.T) {
	parallel(t) // P018 E075
	_, items, err := verifiedKey("TestTableDifferential")
	if err != nil {
		t.Fatal(err)
	}
	all := strings.Join(items, "\n")
	for _, w := range []string{"cmd/spinelbpf/e010_test.go ", "cmd/spinelbpf/e009_test.go ", "cmd/spinelbpf/testdata/table/t_u32.rb ", "internal/frontend/", "ruby/lib/spinelbpf.rb ", "uname -r ", "nproc ", "gcc ", "third_party/spinel/lib/libspinel_rt.a "} {
		if !strings.Contains(all, w) {
			t.Errorf("the key of TestTableDifferential lacks %q", w)
		}
	}
	_, items2, err := verifiedKey("TestPacketHostLoad")
	if err != nil || !strings.Contains(strings.Join(items2, "\n"), "internal/frontend/testdata/pos/") {
		t.Errorf("the key of TestPacketHostLoad lacks internal/frontend/testdata/pos (err %v)", err)
	}
	for _, w := range []string{"cmd/spinelbpf/e044_test.go ", "testdata/ring/"} {
		if strings.Contains(all, w) {
			t.Errorf("the key of TestTableDifferential should not include %q", w)
		}
	}
}
