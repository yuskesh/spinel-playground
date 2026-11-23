package spbpf

import (
	"fmt"
	"io"
	"strings"
)

// Module は 1 つの .mlir に相当する。
type Module struct {
	name     string
	programs []*Program
	err      error
}

func NewModule(name string) *Module { return &Module{name: name} }

// Program を足す。attach 種別は型で受ける (文字列は外から入らない)。
func (m *Module) Program(name string, kind ProgramKind) *Program {
	p := &Program{module: m, name: name, kind: kind}
	m.programs = append(m.programs, p)
	return p
}

func (m *Module) fail(format string, a ...any) {
	if m.err == nil {
		m.err = fmt.Errorf(format, a...)
	}
}

// WriteMLIR は組み立てた module を MLIR テキストとして書く。
// **組み立て中に見つけた誤りはここで返す** — 壊れた IR を出さないため。
func (m *Module) WriteMLIR(w io.Writer) error {
	var sb strings.Builder
	for _, p := range m.programs {
		if err := p.write(&sb); err != nil {
			return err
		}
	}
	if m.err != nil {
		return m.err
	}
	_, err := io.WriteString(w, sb.String())
	return err
}

// Program は 1 つの attach 単位。
type Program struct {
	module   *Module
	name     string
	kind     ProgramKind
	maps     []*MapRef
	ringbufs []*MapRef
	body     *Builder
	counter  int // SSA 名の採番 (入れ子 region と共有する)
}

func (p *Program) nextName() string {
	n := fmt.Sprintf("%%v%d", p.counter)
	p.counter++
	return n
}

// Map は schema symbol に対応する map handle を entry block 引数として足す。
func (p *Program) Map(symbol string, kind MapKind, key, value IntType) *MapRef {
	for _, existing := range p.maps {
		if existing.symbol == symbol {
			p.module.fail("map symbol %q is bound twice in program %q", symbol, p.name)
		}
	}
	m := &MapRef{
		symbol: symbol,
		kind:   kind,
		key:    key,
		value_: value,
		value: Value{
			name: fmt.Sprintf("%%m%d", len(p.maps)),
			ty:   fmt.Sprintf("!spbpf.map<%q, %s, %s>", kind, key, value),
		},
	}
	p.maps = append(p.maps, m)
	return m
}

// RingBuf は ring buffer を map handle として足す。key/value を持たない。
func (p *Program) RingBuf(symbol string) *MapRef {
	for _, existing := range p.maps {
		if existing.symbol == symbol {
			p.module.fail("map symbol %q is bound twice in program %q", symbol, p.name)
		}
	}
	for _, existing := range p.ringbufs {
		if existing.symbol == symbol {
			p.module.fail("ring buffer %q is declared twice in program %q", symbol, p.name)
		}
	}
	// ring buffer は reserve の名前で参照するので entry block 引数にはしない。
	m := &MapRef{symbol: symbol, kind: RingBuf}
	p.ringbufs = append(p.ringbufs, m)
	return m
}

func (p *Program) Body() *Builder {
	if p.body == nil {
		p.body = &Builder{program: p, indent: "  "}
	}
	return p.body
}

func (p *Program) write(sb *strings.Builder) error {
	if p.body == nil || !p.body.hasVerdict {
		return fmt.Errorf("program %q has no verdict", p.name)
	}
	fmt.Fprintf(sb, "spbpf.program @%s %q", p.name, p.kind)
	if len(p.maps) > 0 {
		syms := make([]string, len(p.maps))
		for i, m := range p.maps {
			syms[i] = "@" + m.symbol
		}
		fmt.Fprintf(sb, " maps [%s]", strings.Join(syms, ", "))
	}
	sb.WriteString(" {\n")
	fmt.Fprintf(sb, "^bb0(%%ctx: !spbpf.ctx<%q>", p.kind)
	for _, m := range p.maps {
		fmt.Fprintf(sb, ", %s: %s", m.value, m.value.ty)
	}
	sb.WriteString("):\n")
	sb.WriteString(p.body.buf.String())
	sb.WriteString("}\n")
	return nil
}
