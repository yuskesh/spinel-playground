// P013 Task 9 / E156 checkpoint 2 の Go 側入力境界。stdlib のみで組む
// (otel SDK は依存に入れない — Spinel 固有語彙にも otel SDK にも依存せず、
// schema JSON と record bytes だけから正規化 OTLP data model を独立に構築する
// ことがこの consumer の存在理由)。
module spinel-llvm/examples/ebpf-go/otlp-agent

go 1.25.0
