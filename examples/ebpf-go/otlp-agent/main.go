// otlp-agent — schema JSON と record bytes から**正規化 OTLP data model**を
// 独立に構築する Go consumer (P013 Task 9 / E156 checkpoint 2)。
//
//	otlp-agent -schema schema.json -records records.bin \
//	           -record u_187_xdp_emit_pair_pair_event -wall-offset-ns 1700000000000000000
//
// 出力は stdout へ model JSON のみ。**エラーは全て stderr + exit 1** —
// 未知の telemetry 語彙も、対応できない値も、黙って既定値へ倒したり
// skip したりしない。これが 3 経路差動 (Spinel current / Spinel MLIR / Go) の
// Go 側入力境界であり、その意味は「同じ record から同じ意味の OTLP
// Logs/Metrics を独立に作れるか」を確かめることにある。そのため:
//
//   - Spinel 固有の語彙 (extensions["spinel.ebpf"] 配下の配線など) には触れない。
//   - schema の未知 key は telemetry の signal/metric/timing/source/attribute で
//     厳格に拒否する (json.Decoder.DisallowUnknownFields)。
//   - otel SDK は使わない (go.mod 参照)。model は自前の JSON 構造体。
//
// 対応する語彙と拒否する語彙は README.md にまとめてある。
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"math/bits"
	"os"
	"strconv"
	"strings"
)

func main() {
	schemaPath := flag.String("schema", "", "path to the schema JSON (canonical)")
	recordsPath := flag.String("records", "", "a byte file of concatenated fixed-length records")
	recordSymbol := flag.String("record", "", "symbol of the target record (core.records[].symbol)")
	wallOffsetNs := flag.Int64("wall-offset-ns", 0,
		"offset that turns record_ktime (monotonic) into wall clock ns. "+
			"Expected to be a value sampled once per drain (sampling per record gives path-dependent reordering)")
	flag.Parse()

	if *schemaPath == "" || *recordsPath == "" || *recordSymbol == "" {
		fmt.Fprintln(os.Stderr, "otlp-agent: -schema, -records and -record are required")
		os.Exit(1)
	}

	schemaBytes, err := os.ReadFile(*schemaPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "otlp-agent: cannot read the schema: %v\n", err)
		os.Exit(1)
	}
	recordBytes, err := os.ReadFile(*recordsPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "otlp-agent: cannot read the records: %v\n", err)
		os.Exit(1)
	}

	doc, err := parseSchema(schemaBytes)
	if err != nil {
		fmt.Fprintf(os.Stderr, "otlp-agent: %v\n", err)
		os.Exit(1)
	}
	model, err := buildModel(doc, *recordSymbol, recordBytes, *wallOffsetNs)
	if err != nil {
		fmt.Fprintf(os.Stderr, "otlp-agent: %v\n", err)
		os.Exit(1)
	}

	out, err := json.MarshalIndent(model, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "otlp-agent: cannot turn the model into JSON: %v\n", err)
		os.Exit(1)
	}
	fmt.Println(string(out))
}

// ============================================================================
// schema JSON — 厳格な decode
//
// core.records / core.record.fields / type kind は厳格 decode してよい
// (仕様の指示どおり)。telemetry.signals / metric / timing / source /
// attribute は**必ず**厳格 decode し、未知 key は拒否する。
//
// coverage / version / extensions / core.maps / core.programs は
// json.RawMessage として構造だけ受け取り、中身は解釈しない — この
// consumer が要るのは core.records と telemetry (clocks / signals) だけ。
// telemetry.value_maps / telemetry.bounds_sets も同様に未解釈のまま通す
// (このrecordの対象語彙には出てこない)。
//
// 1 個の json.Decoder に DisallowUnknownFields を立てて 1 回で decode する。
// Go の decoder はネストした struct にも同じ設定を再帰的に効かせるので、
// これで「構造として受けるが解釈しない」部分 (RawMessage) と「厳格 decode
// する」部分 (具体的な struct) を、同じ decode 呼び出しの中で両立できる。
// ============================================================================

type schemaDoc struct {
	Version    json.RawMessage `json:"version"`
	Coverage   json.RawMessage `json:"coverage"`
	Core       coreDoc         `json:"core"`
	Telemetry  telemetryDoc    `json:"telemetry"`
	Extensions json.RawMessage `json:"extensions"`
}

type coreDoc struct {
	Records  []recordDecl    `json:"records"`
	Maps     json.RawMessage `json:"maps"`
	Programs json.RawMessage `json:"programs"`
}

type telemetryDoc struct {
	Clocks     []clockDecl     `json:"clocks"`
	ValueMaps  json.RawMessage `json:"value_maps"`
	BoundsSets json.RawMessage `json:"bounds_sets"`
	Signals    []signalDecl    `json:"signals"`
}

type recordDecl struct {
	Symbol          string      `json:"symbol"`
	ID              uint32      `json:"id"`
	Size            uint64      `json:"size"`
	MinSize         uint64      `json:"min_size"`
	Alignment       uint32      `json:"alignment"`
	RequiredThrough string      `json:"required_through"`
	Note            string      `json:"note"`
	Fields          []fieldDecl `json:"fields"`
}

type fieldDecl struct {
	Name   string   `json:"name"`
	Offset uint64   `json:"offset"`
	Expose string   `json:"expose"`
	Note   string   `json:"note"`
	Type   typeDecl `json:"type"`
}

// typeDecl は "int" と "record_ref" の両方が使う key の和集合として decode する。
// kind ごとにどれが有効かは flattenRecord が対象 record についてのみ検査する
// (schema 全体の他 record にまで検査を広げない — 仕様どおり「対象recordに
// 出たら」エラー)。ただし JSON の key 自体はここで厳格に絞ってあるので、
// "array" など未対応 kind が独自 key ("count"/"element" 等) を持ち込めば
// この時点で decode が拒否する。
type typeDecl struct {
	Kind       string `json:"kind"`
	Bits       uint32 `json:"bits"`
	Signed     bool   `json:"signed"`
	Endianness string `json:"endianness"`
	Alignment  uint32 `json:"alignment"`
	Symbol     string `json:"symbol"`
}

type clockDecl struct {
	ID           string `json:"id"`
	KernelSource string `json:"kernel_source"`
	PosixClock   string `json:"posix_clock"`
	ToWall       string `json:"to_wall"`
	Note         string `json:"note"`
}

// predicateDecl は drop_when と attribute.presence の両方に使う。
// このconsumerが対応するのは op=="never"(drop_when) と op=="always"(presence)
// のみで、operand/index/bytes/args は読まない — が、key 自体は
// requireOnlyKeys の全集合を受け付けないと「未知 key」判定が過剰になる
// (本物の schema には他 op のために存在しうる key)。json.RawMessage で
// 値の型を固定せずに受ける (bytes は JSON 上は数値配列であって base64
// 文字列ではないため、Go の []byte 専用デコードは使えない)。
type predicateDecl struct {
	Op      string          `json:"op"`
	Operand json.RawMessage `json:"operand"`
	Index   json.RawMessage `json:"index"`
	Bytes   json.RawMessage `json:"bytes"`
	Args    json.RawMessage `json:"args"`
	Detail  string          `json:"detail"`
}

type sourceDecl struct {
	Kind   string `json:"kind"`
	Name   string `json:"name"`
	From   string `json:"from"`
	Detail string `json:"detail"`
}

type attributeDecl struct {
	Key       string        `json:"key"`
	Stability string        `json:"stability"`
	Source    sourceDecl    `json:"source"`
	Presence  predicateDecl `json:"presence"`
	Note      string        `json:"note"`
}

type timingDecl struct {
	Start string `json:"start"`
	Clock string `json:"clock"`
	End   string `json:"end"`
}

// metricDecl も sum / exponential_histogram の全 key の和集合。kind ごとの
// 必須 field は buildModel が対象 signal についてのみ検査する。
type metricDecl struct {
	Kind          string   `json:"kind"`
	Unit          string   `json:"unit"`
	Temporality   string   `json:"temporality"`
	Monotonic     *bool    `json:"monotonic"`
	Scale         *int64   `json:"scale"`
	ZeroThreshold *float64 `json:"zero_threshold"`
	BucketRule    string   `json:"bucket_rule"`
}

type signalDecl struct {
	Name       string          `json:"name"`
	Signal     string          `json:"signal"`
	Record     string          `json:"record"`
	SpanName   string          `json:"span_name"`
	SpanKind   string          `json:"span_kind"`
	Timing     timingDecl      `json:"timing"`
	DropWhen   predicateDecl   `json:"drop_when"`
	Attributes []attributeDecl `json:"attributes"`
	Body       *sourceDecl     `json:"body"`
	Value      *sourceDecl     `json:"value"`
	Metric     *metricDecl     `json:"metric"`
	Note       string          `json:"note"`
}

func parseSchema(data []byte) (*schemaDoc, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var doc schemaDoc
	if err := dec.Decode(&doc); err != nil {
		return nil, fmt.Errorf("cannot decode the schema JSON: %w", err)
	}
	if dec.More() {
		return nil, fmt.Errorf("extra data after the schema JSON")
	}
	return &doc, nil
}

// ============================================================================
// record layout — offset 解決
// ============================================================================

// flatField は record_ref を "hdr." のように prefix 展開したあとの、
// 対象 record バッファ内の絶対 offset を持つ 1 field。
type flatField struct {
	Offset uint64
	Bits   uint32
	Signed bool
}

// flattenRecord は symbol の record を対象として、int field を絶対 offset で
// 平坦化する。record_ref は再帰的に展開し、"hdr.timestamp" のような
// dotted path を作る。int/record_ref 以外の type kind が出たら拒否する
// (対象 record についてのみ検査する — 仕様どおり)。
func flattenRecord(records map[string]recordDecl, symbol, prefix string, base uint64, visiting map[string]bool) (map[string]flatField, error) {
	if visiting[symbol] {
		return nil, fmt.Errorf("the record_ref of record %q is cyclic", symbol)
	}
	visiting[symbol] = true
	defer delete(visiting, symbol)

	rec, ok := records[symbol]
	if !ok {
		return nil, fmt.Errorf("record %q is not in core.records", symbol)
	}

	out := map[string]flatField{}
	for _, f := range rec.Fields {
		switch f.Type.Kind {
		case "int":
			switch f.Type.Bits {
			case 8, 16, 32, 64:
			default:
				return nil, fmt.Errorf("record %q field %q: bits %d is not supported (8/16/32/64 only)",
					symbol, f.Name, f.Type.Bits)
			}
			if f.Type.Endianness != "little" {
				return nil, fmt.Errorf("record %q field %q: endianness %q is not supported (little only)",
					symbol, f.Name, f.Type.Endianness)
			}
			out[prefix+f.Name] = flatField{
				Offset: base + f.Offset,
				Bits:   f.Type.Bits,
				Signed: f.Type.Signed,
			}
		case "record_ref":
			sub, err := flattenRecord(records, f.Type.Symbol, prefix+f.Name+".", base+f.Offset, visiting)
			if err != nil {
				return nil, err
			}
			for k, v := range sub {
				out[k] = v
			}
		default:
			return nil, fmt.Errorf("record %q field %q: unsupported type kind %q (int / record_ref only)",
				symbol, f.Name, f.Type.Kind)
		}
	}
	return out, nil
}

// readInt は record バッファの offset から little endian 整数を読む。
// unsigned 64bit で最上位 bit が立っている値は int64 に収まらない —
// 黙って符号を誤読するより、ここで拒否する (対象は kernel の ktime/カウンタ
// なので実運用では起きないが、起きたら気付けるようにする)。
func readInt(buf []byte, off uint64, bitsN uint32, signed bool) (int64, error) {
	width := uint64(bitsN / 8)
	if off+width > uint64(len(buf)) {
		return 0, fmt.Errorf("field (offset=%d, bits=%d) runs past the record's %d bytes",
			off, bitsN, len(buf))
	}
	switch bitsN {
	case 8:
		v := buf[off]
		if signed {
			return int64(int8(v)), nil
		}
		return int64(v), nil
	case 16:
		v := binary.LittleEndian.Uint16(buf[off:])
		if signed {
			return int64(int16(v)), nil
		}
		return int64(v), nil
	case 32:
		v := binary.LittleEndian.Uint32(buf[off:])
		if signed {
			return int64(int32(v)), nil
		}
		return int64(v), nil
	case 64:
		v := binary.LittleEndian.Uint64(buf[off:])
		if signed {
			return int64(v), nil
		}
		if v > math.MaxInt64 {
			return 0, fmt.Errorf("field (offset=%d): the unsigned 64-bit value %d does not fit in int64", off, v)
		}
		return int64(v), nil
	}
	return 0, fmt.Errorf("field (offset=%d): bits %d is not supported", off, bitsN)
}

// ============================================================================
// model JSON — 出力形
// ============================================================================

type modelOut struct {
	LogRecords            []logRecordOut `json:"log_records"`
	Sums                  []sumOut       `json:"sums"`
	ExponentialHistograms []expHistOut   `json:"exponential_histograms"`
}

type logRecordOut struct {
	TimeUnixNano int64          `json:"time_unix_nano"`
	Body         bodyOut        `json:"body"`
	Attributes   map[string]any `json:"attributes"`
}

type bodyOut struct {
	Int int64 `json:"int"`
}

type sumOut struct {
	Name        string            `json:"name"`
	Unit        string            `json:"unit"`
	Temporality string            `json:"temporality"`
	IsMonotonic bool              `json:"is_monotonic"`
	DataPoints  []sumDataPointOut `json:"data_points"`
}

type sumDataPointOut struct {
	Attributes        map[string]any `json:"attributes"`
	StartTimeUnixNano int64          `json:"start_time_unix_nano"`
	TimeUnixNano      int64          `json:"time_unix_nano"`
	Value             int64          `json:"value"`
}

type expHistOut struct {
	Name        string                `json:"name"`
	Unit        string                `json:"unit"`
	Temporality string                `json:"temporality"`
	DataPoints  []expHistDataPointOut `json:"data_points"`
}

type bucketsOut struct {
	Offset       int64   `json:"offset"`
	BucketCounts []int64 `json:"bucket_counts"`
}

type expHistDataPointOut struct {
	Attributes        map[string]any `json:"attributes"`
	Scale             int64          `json:"scale"`
	ZeroCount         int64          `json:"zero_count"`
	Count             int64          `json:"count"`
	Sum               int64          `json:"sum"`
	Positive          bucketsOut     `json:"positive"`
	Negative          bucketsOut     `json:"negative"`
	StartTimeUnixNano int64          `json:"start_time_unix_nano"`
	TimeUnixNano      int64          `json:"time_unix_nano"`
}

// ============================================================================
// telemetry → model
// ============================================================================

// buildModel は対象 record を指す signal だけから model を作る。
// 空 model を黙って成功にしない: 対象 record への signal が 1 つも無ければ
// エラーで落ちる (schema が coverage.telemetry=complete を申告していながら
// 空を返す silent skip を作らないため — E156 checkpoint 1 で実際に踏んだ)。
func buildModel(doc *schemaDoc, recordSymbol string, recordBytes []byte, wallOffsetNs int64) (*modelOut, error) {
	records := map[string]recordDecl{}
	for _, r := range doc.Core.Records {
		if _, dup := records[r.Symbol]; dup {
			return nil, fmt.Errorf("core.records: record symbol %q is duplicated", r.Symbol)
		}
		records[r.Symbol] = r
	}
	target, ok := records[recordSymbol]
	if !ok {
		return nil, fmt.Errorf("record %q is not in core.records", recordSymbol)
	}
	if target.Size == 0 {
		return nil, fmt.Errorf("the size of record %q is 0", recordSymbol)
	}

	fields, err := flattenRecord(records, recordSymbol, "", 0, map[string]bool{})
	if err != nil {
		return nil, err
	}

	if len(recordBytes)%int(target.Size) != 0 {
		return nil, fmt.Errorf("the records byte length %d is not a multiple of the record size %d (length mismatch)",
			len(recordBytes), target.Size)
	}
	n := len(recordBytes) / int(target.Size)
	chunks := make([][]byte, n)
	for i := 0; i < n; i++ {
		chunks[i] = recordBytes[i*int(target.Size) : (i+1)*int(target.Size)]
	}

	clockIDs := map[string]bool{}
	for _, c := range doc.Telemetry.Clocks {
		clockIDs[c.ID] = true
	}

	var targeted []signalDecl
	for _, s := range doc.Telemetry.Signals {
		if s.Record == recordSymbol {
			targeted = append(targeted, s)
		}
	}
	if len(targeted) == 0 {
		return nil, fmt.Errorf("no telemetry signal points at record %q (telemetry is empty)", recordSymbol)
	}

	model := &modelOut{
		LogRecords:            []logRecordOut{},
		Sums:                  []sumOut{},
		ExponentialHistograms: []expHistOut{},
	}

	for _, s := range targeted {
		switch s.Signal {
		case "traces":
			return nil, fmt.Errorf("signal %q: the signal kind \"traces\" is outside this agent", s.Name)

		case "logs":
			lrs, err := buildLogRecords(s, chunks, fields, clockIDs, wallOffsetNs)
			if err != nil {
				return nil, fmt.Errorf("signal %q: %w", s.Name, err)
			}
			model.LogRecords = append(model.LogRecords, lrs...)

		case "metrics":
			if err := buildMetric(s, chunks, fields, clockIDs, wallOffsetNs, model); err != nil {
				return nil, fmt.Errorf("signal %q: %w", s.Name, err)
			}

		default:
			return nil, fmt.Errorf("signal %q: the signal kind %q is not supported (logs / metrics only; traces is outside)",
				s.Name, s.Signal)
		}
	}

	return model, nil
}

// validateTiming は timing.start が "record_ktime:<fieldpath>" 形式であること、
// clock が telemetry.clocks に実在すること、end が "start" のみであることを
// 検査し、fieldpath を返す。
func validateTiming(t timingDecl, clockIDs map[string]bool) (string, error) {
	const prefix = "record_ktime:"
	if !strings.HasPrefix(t.Start, prefix) {
		return "", fmt.Errorf("timing.start %q: only the form \"record_ktime:<fieldpath>\" is supported", t.Start)
	}
	fieldPath := strings.TrimPrefix(t.Start, prefix)
	if fieldPath == "" {
		return "", fmt.Errorf("timing.start has no fieldpath")
	}
	if !clockIDs[t.Clock] {
		return "", fmt.Errorf("timing.clock %q does not exist in telemetry.clocks", t.Clock)
	}
	if t.End != "start" {
		return "", fmt.Errorf("timing.end %q is not supported (\"start\" only)", t.End)
	}
	return fieldPath, nil
}

func validateDropNever(p predicateDecl) error {
	if p.Op != "never" {
		return fmt.Errorf("drop_when.op %q is not supported ({\"op\":\"never\"} only)", p.Op)
	}
	return nil
}

func eventTimeNanos(chunk []byte, fields map[string]flatField, fieldPath string, wallOffsetNs int64) (int64, error) {
	ff, ok := fields[fieldPath]
	if !ok {
		return 0, fmt.Errorf("the fieldpath %q of timing.start is not in the record", fieldPath)
	}
	v, err := readInt(chunk, ff.Offset, ff.Bits, ff.Signed)
	if err != nil {
		return 0, fmt.Errorf("timing.start %q: %w", fieldPath, err)
	}
	return v + wallOffsetNs, nil
}

// buildAttributes は source.kind=="field" + presence.op=="always" のみ対応する。
// それ以外は拒否する (黙って attribute を落とさない)。
func buildAttributes(attrs []attributeDecl, chunk []byte, fields map[string]flatField) (map[string]any, error) {
	out := make(map[string]any, len(attrs))
	for _, a := range attrs {
		if a.Presence.Op != "always" {
			return nil, fmt.Errorf("attribute %q: presence.op %q is not supported ({\"op\":\"always\"} only)",
				a.Key, a.Presence.Op)
		}
		if a.Source.Kind != "field" {
			return nil, fmt.Errorf("attribute %q: source.kind %q is not supported (\"field\" only)",
				a.Key, a.Source.Kind)
		}
		ff, ok := fields[a.Source.Name]
		if !ok {
			return nil, fmt.Errorf("attribute %q: field %q is not in the record", a.Key, a.Source.Name)
		}
		v, err := readInt(chunk, ff.Offset, ff.Bits, ff.Signed)
		if err != nil {
			return nil, fmt.Errorf("attribute %q: %w", a.Key, err)
		}
		out[a.Key] = v
	}
	return out, nil
}

// buildLogRecords は logs signal から record 1 件につき LogRecord 1 件を作る。
// **入力順を保存する** (record bytes ファイルに現れた順)。
func buildLogRecords(s signalDecl, chunks [][]byte, fields map[string]flatField, clockIDs map[string]bool, wallOffsetNs int64) ([]logRecordOut, error) {
	if s.Body == nil {
		return nil, fmt.Errorf("the logs signal has no body")
	}
	if s.Body.Kind != "field" {
		return nil, fmt.Errorf("body.kind %q is not supported (\"field\" only)", s.Body.Kind)
	}
	bodyField, ok := fields[s.Body.Name]
	if !ok {
		return nil, fmt.Errorf("body.name %q is not in the record", s.Body.Name)
	}
	if err := validateDropNever(s.DropWhen); err != nil {
		return nil, err
	}
	fieldPath, err := validateTiming(s.Timing, clockIDs)
	if err != nil {
		return nil, err
	}

	out := make([]logRecordOut, 0, len(chunks))
	for _, chunk := range chunks {
		t, err := eventTimeNanos(chunk, fields, fieldPath, wallOffsetNs)
		if err != nil {
			return nil, err
		}
		bv, err := readInt(chunk, bodyField.Offset, bodyField.Bits, bodyField.Signed)
		if err != nil {
			return nil, fmt.Errorf("body.name %q: %w", s.Body.Name, err)
		}
		attrs, err := buildAttributes(s.Attributes, chunk, fields)
		if err != nil {
			return nil, err
		}
		out = append(out, logRecordOut{
			TimeUnixNano: t,
			Body:         bodyOut{Int: bv},
			Attributes:   attrs,
		})
	}
	return out, nil
}

// resolveMetricValue は metrics signal の value (Source) を record 1 件から
// 数値へ解決する。field: record field の値。constant: name を10進整数
// リテラルとして読む (record 1件につきその値)。
func resolveMetricValue(src sourceDecl, chunk []byte, fields map[string]flatField) (int64, error) {
	switch src.Kind {
	case "field":
		ff, ok := fields[src.Name]
		if !ok {
			return 0, fmt.Errorf("value.name %q is not in the record", src.Name)
		}
		return readInt(chunk, ff.Offset, ff.Bits, ff.Signed)
	case "constant":
		v, err := strconv.ParseInt(src.Name, 10, 64)
		if err != nil {
			return 0, fmt.Errorf("value.name %q is not a decimal integer literal: %w", src.Name, err)
		}
		return v, nil
	default:
		return 0, fmt.Errorf("value.kind %q is not supported (\"field\" / \"constant\" only)", src.Kind)
	}
}

// buildMetric は metrics signal を sum または exponential_histogram として
// model に足す。metric.kind がそれ以外なら拒否する。
func buildMetric(s signalDecl, chunks [][]byte, fields map[string]flatField, clockIDs map[string]bool, wallOffsetNs int64, model *modelOut) error {
	if s.Value == nil {
		return fmt.Errorf("the metrics signal has no value")
	}
	if s.Metric == nil {
		return fmt.Errorf("the metrics signal has no metric")
	}
	if err := validateDropNever(s.DropWhen); err != nil {
		return err
	}
	fieldPath, err := validateTiming(s.Timing, clockIDs)
	if err != nil {
		return err
	}
	if len(chunks) == 0 {
		return fmt.Errorf("0 records, so the metric cannot be aggregated")
	}

	staticAttrs, err := buildAttributes(s.Attributes, chunks[0], fields)
	if err != nil {
		return err
	}

	switch s.Metric.Kind {
	case "sum":
		return buildSum(s, chunks, fields, fieldPath, wallOffsetNs, staticAttrs, model)
	case "exponential_histogram":
		return buildExpHistogram(s, chunks, fields, fieldPath, wallOffsetNs, staticAttrs, model)
	default:
		return fmt.Errorf("metric.kind %q is not supported (\"sum\" / \"exponential_histogram\" only)", s.Metric.Kind)
	}
}

func validTemporality(t string) bool { return t == "delta" || t == "cumulative" }

func buildSum(s signalDecl, chunks [][]byte, fields map[string]flatField, fieldPath string, wallOffsetNs int64, staticAttrs map[string]any, model *modelOut) error {
	m := s.Metric
	if m.Monotonic == nil {
		return fmt.Errorf("metric.kind \"sum\" needs monotonic")
	}
	if !validTemporality(m.Temporality) {
		return fmt.Errorf("metric.temporality %q is not supported (\"delta\" / \"cumulative\" only)", m.Temporality)
	}

	var total int64
	minT, maxT := int64(math.MaxInt64), int64(math.MinInt64)
	for _, chunk := range chunks {
		v, err := resolveMetricValue(*s.Value, chunk, fields)
		if err != nil {
			return err
		}
		total += v
		t, err := eventTimeNanos(chunk, fields, fieldPath, wallOffsetNs)
		if err != nil {
			return err
		}
		if t < minT {
			minT = t
		}
		if t > maxT {
			maxT = t
		}
	}

	model.Sums = append(model.Sums, sumOut{
		Name:        s.Name,
		Unit:        m.Unit,
		Temporality: m.Temporality,
		IsMonotonic: *m.Monotonic,
		DataPoints: []sumDataPointOut{{
			Attributes:        staticAttrs,
			StartTimeUnixNano: minT,
			TimeUnixNano:      maxT,
			Value:             total,
		}},
	})
	return nil
}

// expBucketIndex は otlp_lower_exclusive (scale=0) の bucket index を計算する。
// v>=1 が前提: 2^i < v <= 2^(i+1) を満たす i。整数演算では
// i = bits.Len64(uint64(v-1)) - 1 (v=1→i=-1, v=8→2, v=9→3)。
func expBucketIndex(v int64) (int64, error) {
	if v < 1 {
		return 0, fmt.Errorf("the value %d sent to a positive bucket is below 1 (check the zero_threshold setting)", v)
	}
	return int64(bits.Len64(uint64(v-1))) - 1, nil
}

func buildExpHistogram(s signalDecl, chunks [][]byte, fields map[string]flatField, fieldPath string, wallOffsetNs int64, staticAttrs map[string]any, model *modelOut) error {
	m := s.Metric
	if m.Scale == nil {
		return fmt.Errorf("metric.kind \"exponential_histogram\" needs scale")
	}
	if *m.Scale != 0 {
		return fmt.Errorf("metric.scale %d is not supported (0 only)", *m.Scale)
	}
	if m.ZeroThreshold == nil {
		return fmt.Errorf("metric.kind \"exponential_histogram\" needs zero_threshold")
	}
	if m.BucketRule != "otlp_lower_exclusive" {
		return fmt.Errorf("metric.bucket_rule %q is not supported (\"otlp_lower_exclusive\" only)", m.BucketRule)
	}
	if !validTemporality(m.Temporality) {
		return fmt.Errorf("metric.temporality %q is not supported (\"delta\" / \"cumulative\" only)", m.Temporality)
	}
	zeroThreshold := *m.ZeroThreshold

	var zeroCount, count, sum int64
	counts := map[int64]int64{}
	haveIdx := false
	var minIdx, maxIdx int64
	minT, maxT := int64(math.MaxInt64), int64(math.MinInt64)

	for _, chunk := range chunks {
		v, err := resolveMetricValue(*s.Value, chunk, fields)
		if err != nil {
			return err
		}
		if v < 0 {
			return fmt.Errorf("value %d is negative (negative buckets are not implemented)", v)
		}
		sum += v
		count++
		if float64(v) <= zeroThreshold {
			zeroCount++
		} else {
			idx, err := expBucketIndex(v)
			if err != nil {
				return err
			}
			counts[idx]++
			if !haveIdx || idx < minIdx {
				minIdx = idx
			}
			if !haveIdx || idx > maxIdx {
				maxIdx = idx
			}
			haveIdx = true
		}
		t, err := eventTimeNanos(chunk, fields, fieldPath, wallOffsetNs)
		if err != nil {
			return err
		}
		if t < minT {
			minT = t
		}
		if t > maxT {
			maxT = t
		}
	}

	var offset int64
	bucketCounts := []int64{}
	if haveIdx {
		offset = minIdx
		bucketCounts = make([]int64, maxIdx-minIdx+1)
		for idx, c := range counts {
			bucketCounts[idx-minIdx] = c
		}
	}

	model.ExponentialHistograms = append(model.ExponentialHistograms, expHistOut{
		Name:        s.Name,
		Unit:        m.Unit,
		Temporality: m.Temporality,
		DataPoints: []expHistDataPointOut{{
			Attributes:        staticAttrs,
			Scale:             0,
			ZeroCount:         zeroCount,
			Count:             count,
			Sum:               sum,
			Positive:          bucketsOut{Offset: offset, BucketCounts: bucketCounts},
			Negative:          bucketsOut{Offset: 0, BucketCounts: []int64{}},
			StartTimeUnixNano: minT,
			TimeUnixNano:      maxT,
		}},
	})
	return nil
}
