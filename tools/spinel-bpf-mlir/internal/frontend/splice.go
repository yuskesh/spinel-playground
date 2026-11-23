package frontend

import (
	"strings"
)

// Spinel の builtins の継ぎ込みの行のずれの補正 (upstream_suspects S11 — E055 で見つけ、E056 で SB000 の全ての停止を補正に狭めた)。
// source が Enumerable の method の名前を含むと Spinel は builtins/enumerable.rb (続けて enumerator.rb) を継ぎ込み、source の頭に require の行を
// 足すので、利用者の file (FILE 0) の node の node_line が k だけ大きく報告される。足した require の node は AST に残らない — k は名前を持つ node の
// 位置の原文との照らしで測る。同じ Spinel の run の --emit-types の record も同じだけずれる — AST と record を同じ k で戻す (型の引きの鍵は揃ったまま)。

// spliceMaxShift は測る k の上限 (E056 — 継ぎ込む builtins は今 2 つで測った最大は +2、余裕を 2 つ。超えれば合う k が無く SB000)。
const spliceMaxShift = 4

// spliced は AST に Spinel の builtins の file が在るか。
func spliced(a *AST) bool {
	// enumerable・enumerator だけでなく integer・comparable も source の頭に require を足す (E058 で library の局所変数 `digits` が integer.rb を継ぎ込んで見つけた)
	for _, p := range a.Files {
		if strings.Contains(p, "/builtins/") {
			return true
		}
	}
	return false
}

// anchors は FILE fid の名前を持つ node と、source の行のその列から始まるべき原文。
func anchors(a *AST, fid int) []struct {
	n    *Node
	want string
} {
	var out []struct {
		n    *Node
		want string
	}
	add := func(n *Node, w string) {
		if w != "" {
			out = append(out, struct {
				n    *Node
				want string
			}{n, w})
		}
	}
	for _, n := range a.Nodes {
		if n == nil || n.FileID != fid || n.Line <= 0 {
			continue
		}
		switch n.Type {
		case "ConstantWriteNode", "ConstantReadNode", "LocalVariableWriteNode":
			add(n, n.Str["name"])
		case "DefNode":
			add(n, "def")
		case "CallNode":
			// 受け手の無い呼び出しだけ (受け手の在る呼び出しの列は受け手の始まり)。演算子の名前は外す
			if _, has := n.Ref["receiver"]; !has && n.Str["name"] != "" && !strings.ContainsAny(n.Str["name"], "=[]+-*/<>!%&|^~") {
				add(n, n.Str["name"])
			}
		}
	}
	return out
}

// measureShift は k (0..spliceMaxShift) のうち、全ての anchor の原文が source の (line − k) 行の col から始まるものを返す。ちょうど 1 つでなければ ok = false。
func measureShift(a *AST, fid int, lines []string) (int, bool) {
	as := anchors(a, fid)
	if len(as) == 0 {
		return 0, false
	}
	found, k := 0, -1
	for c := 0; c <= spliceMaxShift; c++ {
		all := true
		for _, x := range as {
			l := x.n.Line - c
			if l < 1 || l > len(lines) || x.n.Col < 0 || x.n.Col > len(lines[l-1]) || !strings.HasPrefix(lines[l-1][x.n.Col:], x.want) {
				all = false
				break
			}
		}
		if all {
			found++
			k = c
		}
	}
	return k, found == 1
}

// shiftUser は FILE fid の node と、その file の型・codegen・診断の record の行を k だけ戻し、型の引きを作り直す。
func shiftUser(an *Analysis, fid, k int) {
	if k == 0 {
		return
	}
	a := an.AST
	for _, n := range a.Nodes {
		if n != nil && n.FileID == fid {
			n.Line -= k
			if n.EndLine > 0 {
				n.EndLine -= k
			}
		}
	}
	path := a.Files[fid]
	t := an.Types
	for i := range t.Types {
		if t.Types[i].File == path {
			t.Types[i].Line -= k
			t.Types[i].EndLine -= k
		}
	}
	for i := range t.Codegen {
		if t.Codegen[i].File == path {
			t.Codegen[i].Line -= k
			t.Codegen[i].EndLine -= k
		}
	}
	for i := range t.Diagnostics {
		if t.Diagnostics[i].File == path {
			t.Diagnostics[i].Line -= k
		}
	}
	reindex(t)
}

// alignSplice は継ぎ込みが在れば k を測って戻す。継ぎ込みが無ければ何もしない (ok)。測れなければ ok = false (呼び手が SB000)。
func alignSplice(an *Analysis, base, text string) (k int, ok bool) {
	if an == nil || an.AST == nil || !spliced(an.AST) {
		return 0, true
	}
	fid := userFileID(an.AST, base)
	if fid < 0 {
		return 0, false
	}
	k, ok = measureShift(an.AST, fid, strings.Split(text, "\n"))
	if !ok {
		return 0, false
	}
	shiftUser(an, fid, k)
	return k, true
}
