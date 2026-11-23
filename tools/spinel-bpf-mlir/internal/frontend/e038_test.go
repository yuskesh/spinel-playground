package frontend

import "testing"

// TestPerCPUExempt は E038 の H2 (P009 のレビューの P2): per-CPU の SB019 の免除の条件の検査 — map が per-CPU で program の種類が全て xdp のときだけ免除。
// 今の frontend の program の種類は xdp だけなので、XDP でない種類が在る場合は関数の単体の試験で見る (種類を足した時に黙って免除が漏れる形を入口で閉じる)。
func TestPerCPUExempt(t *testing.T) {
	pa := &MapDecl{Kind: "percpu_array"}
	ph := &MapDecl{Kind: "percpu_hash"}
	for _, c := range []struct {
		name  string
		m     *MapDecl
		kinds []string
		want  bool
	}{
		{"percpu_array, all xdp", pa, []string{"xdp", "xdp"}, true},
		{"percpu_hash, all xdp", ph, []string{"xdp"}, true},
		{"percpu_array, a kprobe program too", pa, []string{"xdp", "kprobe"}, false},
		{"percpu_hash, fentry only", ph, []string{"fentry"}, false},
		{"percpu_array, a sched_cls program too (P019 E076 — tc は xdp だけのまま)", pa, []string{"xdp", "sched_cls"}, false},
		{"percpu_hash, sched_cls only", ph, []string{"sched_cls"}, false},
		{"percpu_array, perf_event", pa, []string{"perf_event", "xdp"}, false},
		{"percpu, no programs", pa, nil, false},
		{"shared array", &MapDecl{}, []string{"xdp"}, false},
		{"shared hash", &MapDecl{Kind: "hash"}, []string{"xdp"}, false},
		{"lru_hash", &MapDecl{Kind: "lru_hash"}, []string{"xdp"}, false},
		{"nil map", nil, []string{"xdp"}, false},
	} {
		if got := perCPUExempt(c.m, c.kinds); got != c.want {
			t.Errorf("%s: perCPUExempt = %v, want %v", c.name, got, c.want)
		}
	}
}
