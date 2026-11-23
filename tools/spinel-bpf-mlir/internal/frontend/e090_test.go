package frontend

import "testing"

// frozenCodes は reason code の番号と名前の表 (P022 E090 — v0.1.0 で凍結)。追加は末尾の番号だけ (SB034 から)、番号の再利用・改名はしない —
// 変えたら docs/release.md の表と次の release notes に差を名指す。
var frozenCodes = []struct{ code, name string }{
	{"SB000", "Spinel"}, {"SB001", "UnsupportedConstruct"}, {"SB002", "UnsupportedCall"}, {"SB003", "CrossDomainUse"},
	{"SB004", "UnknownEdge"}, {"SB005", "RefCheckShape"}, {"SB006", "NonConstant"}, {"SB007", "ReservedName"},
	{"SB008", "ProgramShape"}, {"SB009", "OperatorRedefined"}, {"SB010", "TypingProbe"}, {"SB011", "ShadowedName"},
	{"SB012", "ThreadInUserSide"}, {"SB013", "MapDeclShape"}, {"SB014", "SemanticGap"}, {"SB015", "AmbiguousType"},
	{"SB016", "DynamicProgram"}, {"SB017", "InternalEmitter"}, {"SB018", "LogicalSideEffect"}, {"SB019", "SharedReadModifyWrite"},
	{"SB020", "KeyOutOfRange"}, {"SB021", "CompileWarning"}, {"SB022", "WindowIndex"}, {"SB023", "PacketOffset"},
	{"SB024", "RecordShape"}, {"SB025", "DroppedEvent"}, {"SB026", "StatusIgnored"}, {"SB027", "ThreadInBPFSide"},
	{"SB028", "TracingKind"}, {"SB029", "GlobalShape"}, {"SB030", "LoopShape"}, {"SB031", "IndexRange"},
	{"SB032", "UprobeTarget"}, {"SB033", "KernelTypeShape"},
	{"SB034", "SubprogramShape"}, {"SB035", "Recursion"}, // P023 E092 (v0.1.0 の後に足した — 次の release の notes に)
}

// TestCodesFrozen は E090 の H3: codeNames が凍結の表と番号・名前で同じ (足した code は表の末尾に足す — 足しただけでも落ちて表の更新を強いる)。
func TestCodesFrozen(t *testing.T) {
	if len(codeNames) != len(frozenCodes) {
		t.Errorf("codeNames has %d codes, the frozen table %d — append new codes to frozenCodes (and docs/release.md)", len(codeNames), len(frozenCodes))
	}
	for _, f := range frozenCodes {
		if n, ok := codeNames[Code(f.code)]; !ok || n != f.name {
			t.Errorf("%s: frozen name %q, codeNames has %q (present %v) — reason codes are not renamed or reused", f.code, f.name, n, ok)
		}
	}
}
