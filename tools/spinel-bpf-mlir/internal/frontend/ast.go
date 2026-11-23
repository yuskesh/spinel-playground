package frontend

import (
	"bufio"
	"fmt"
	"strconv"
	"strings"
)

// Spinel の text AST (third_party/spinel/docs/internals/AST.md) の reader。
// 1 行 1 record: `ROOT <id>`・`SOURCE_FILE <path>`・`FILE <fid> <path>`・`N <id> <Type>`・`S|I|F <id> <field> <value>`・`R <id> <field> <id|-1>`・`A <id> <field> <id,…>`。
// `--dump-ast --emit-types` で node に `node_end_line` / `node_end_col` が付く (E002 — 付かない node があれば読みの誤りにする)。

// Node は AST の node 1 つ。列は Prism の 0 から。
type Node struct {
	ID      int
	Type    string
	Str     map[string]string
	Int     map[string]int64
	IntText map[string]string // I の値の原文 (範囲外の literal の検査に — Spinel が丸めていないかを見る)
	Ref     map[string]int
	Arr     map[string][]int
	FileID  int
	Line    int
	Col     int
	EndLine int
	EndCol  int
}

// AST は読んだ木。
type AST struct {
	Root       int
	SourceFile string
	Files      map[int]string
	Nodes      map[int]*Node
	Parent     map[int]int
}

func (a *AST) node(id int) *Node {
	if id < 0 {
		return nil
	}
	return a.Nodes[id]
}

// File は node の file の path。
func (a *AST) File(n *Node) string { return a.Files[n.FileID] }

// ref は単一の子 (無ければ nil)。
func (a *AST) ref(n *Node, field string) *Node {
	id, ok := n.Ref[field]
	if !ok {
		return nil
	}
	return a.node(id)
}

// arr は子の並び。
func (a *AST) arr(n *Node, field string) []*Node {
	var out []*Node
	for _, id := range n.Arr[field] {
		if c := a.node(id); c != nil {
			out = append(out, c)
		}
	}
	return out
}

// ParseAST は text AST を読む。形の崩れは誤り (黙って飛ばさない)。
func ParseAST(text string) (*AST, error) {
	a := &AST{Root: -1, Files: map[int]string{}, Nodes: map[int]*Node{}, Parent: map[int]int{}}
	get := func(id int) *Node {
		n := a.Nodes[id]
		if n == nil {
			n = &Node{ID: id, Str: map[string]string{}, Int: map[string]int64{}, IntText: map[string]string{}, Ref: map[string]int{}, Arr: map[string][]int{}, FileID: -1}
			a.Nodes[id] = n
		}
		return n
	}
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 1<<20), 1<<30)
	ln := 0
	for sc.Scan() {
		ln++
		line := sc.Text()
		if line == "" {
			continue
		}
		bad := func(why string) error { return fmt.Errorf("spinel AST line %d: %s: %q", ln, why, line) }
		tag, rest, _ := strings.Cut(line, " ")
		switch tag {
		case "ROOT":
			id, err := strconv.Atoi(rest)
			if err != nil {
				return nil, bad("ROOT id")
			}
			a.Root = id
		case "SOURCE_FILE":
			a.SourceFile = unescape(rest)
		case "FILE":
			fid, p, ok := strings.Cut(rest, " ")
			id, err := strconv.Atoi(fid)
			if !ok || err != nil {
				return nil, bad("FILE record")
			}
			a.Files[id] = unescape(p)
		case "N", "S", "I", "F", "R", "A":
			f := strings.SplitN(rest, " ", 3)
			id, err := strconv.Atoi(f[0])
			if err != nil || len(f) < 2 {
				return nil, bad("record id")
			}
			n := get(id)
			if tag == "N" {
				if n.Type != "" {
					return nil, bad("node declared twice")
				}
				n.Type = f[1]
				continue
			}
			field, val := f[1], ""
			if len(f) == 3 {
				val = f[2]
			}
			switch tag {
			case "S", "F":
				n.Str[field] = unescape(val)
			case "I":
				v, err := strconv.ParseInt(val, 10, 64)
				if err != nil {
					// 64 bit に入らない整数の原文は残す (literal の範囲の検査は原文で — Spinel の丸めを信じない)
					n.IntText[field] = val
					continue
				}
				n.IntText[field] = val
				switch field {
				case "node_file":
					n.FileID = int(v)
				case "node_line":
					n.Line = int(v)
				case "node_col":
					n.Col = int(v)
				case "node_end_line":
					n.EndLine = int(v)
				case "node_end_col":
					n.EndCol = int(v)
				default:
					n.Int[field] = v
				}
			case "R":
				c, err := strconv.Atoi(val)
				if err != nil {
					return nil, bad("R child id")
				}
				n.Ref[field] = c
				if c >= 0 {
					a.Parent[c] = id
				}
			case "A":
				var ids []int
				if val != "" {
					for _, s := range strings.Split(val, ",") {
						c, err := strconv.Atoi(s)
						if err != nil {
							return nil, bad("A child id")
						}
						ids = append(ids, c)
						a.Parent[c] = id
					}
				}
				n.Arr[field] = ids
			}
		default:
			return nil, bad("unknown record tag")
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if a.Root < 0 || a.Nodes[a.Root] == nil {
		return nil, fmt.Errorf("spinel AST: no ROOT node")
	}
	for id, n := range a.Nodes {
		if n.Type == "" {
			return nil, fmt.Errorf("spinel AST: node %d has attributes but no N record", id)
		}
		// 位置の無い node (BlockParametersNode 等 — E002) は読める。型の join では型の無い node になる (受ける形なら Unknown で止まる)
		if n.FileID < 0 {
			continue
		}
		if _, ok := a.Files[n.FileID]; !ok {
			return nil, fmt.Errorf("spinel AST: node %d names file id %d with no FILE record", id, n.FileID)
		}
	}
	return a, nil
}

// unescape は spinel_parse.c の escape_str の逆。実装は `%XX` の percent エンコード (`%` → %25、改行 → %0A、CR → %0D、tab → %09、空白 → %20、NUL → %00)。
// docs/internals/AST.md は backslash のエスケープと書くが実装と違う (docs/upstream_suspects.md S4 — E008 で `%` の演算子の名前 `%25` から見つけた)。
// `%` は必ずエスケープされるので、全ての `%XX` を復号してよい。
func unescape(s string) string {
	if !strings.Contains(s, "%") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '%' && i+2 < len(s) {
			if v, err := strconv.ParseUint(s[i+1:i+3], 16, 8); err == nil {
				b.WriteByte(byte(v))
				i += 2
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}
