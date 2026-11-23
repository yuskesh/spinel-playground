package main

import (
	"encoding/binary"
	"strings"
	"testing"
)

// testSchema は 187_xdp_emit_pair の pair record 相当の schema。
// 187.schema.json (spbpf-compile の実出力) と同形にしてある:
// hdr (16B: type u16 / version u16 / reserved u32 / timestamp u64) +
// a s64 @16 + b s64 @24 = 32B。signal は logs 1 個 (body=a) /
// metrics sum 1 個 (value=a) / metrics exponential_histogram 1 個 (value=b)。
const testSchema = `{
  "version": 1,
  "coverage": {"programs": "complete", "maps": "complete", "records": "complete", "telemetry": "complete"},
  "core": {
    "records": [
      {
        "symbol": "spnl_event_hdr", "id": 0, "size": 16, "min_size": 16, "alignment": 8,
        "required_through": "", "note": "",
        "fields": [
          {"name": "type", "offset": 0, "expose": "", "note": "",
           "type": {"kind": "int", "bits": 16, "signed": false, "endianness": "little", "alignment": 2}},
          {"name": "version", "offset": 2, "expose": "", "note": "",
           "type": {"kind": "int", "bits": 16, "signed": false, "endianness": "little", "alignment": 2}},
          {"name": "reserved", "offset": 4, "expose": "", "note": "",
           "type": {"kind": "int", "bits": 32, "signed": false, "endianness": "little", "alignment": 4}},
          {"name": "timestamp", "offset": 8, "expose": "", "note": "",
           "type": {"kind": "int", "bits": 64, "signed": false, "endianness": "little", "alignment": 8}}
        ]
      },
      {
        "symbol": "u_187_xdp_emit_pair_pair_event", "id": 258, "size": 32, "min_size": 32, "alignment": 8,
        "required_through": "", "note": "",
        "fields": [
          {"name": "hdr", "offset": 0, "expose": "", "note": "",
           "type": {"kind": "record_ref", "symbol": "spnl_event_hdr"}},
          {"name": "a", "offset": 16, "expose": "", "note": "",
           "type": {"kind": "int", "bits": 64, "signed": true, "endianness": "little", "alignment": 8}},
          {"name": "b", "offset": 24, "expose": "", "note": "",
           "type": {"kind": "int", "bits": 64, "signed": true, "endianness": "little", "alignment": 8}}
        ]
      }
    ],
    "maps": [],
    "programs": []
  },
  "telemetry": {
    "clocks": [
      {"id": "monotonic", "kernel_source": "bpf_ktime_get_ns()", "posix_clock": "CLOCK_MONOTONIC",
       "to_wall": "wall_unix_ns = ktime_ns + (clock_gettime(CLOCK_REALTIME) - clock_gettime(CLOCK_MONOTONIC))",
       "note": ""}
    ],
    "value_maps": [],
    "bounds_sets": [],
    "signals": [
      {
        "name": "spnl.pair.log", "signal": "logs", "record": "u_187_xdp_emit_pair_pair_event",
        "span_name": "", "span_kind": "", "note": "",
        "timing": {"start": "record_ktime:hdr.timestamp", "clock": "monotonic", "end": "start"},
        "drop_when": {"op": "never"},
        "body": {"kind": "field", "name": "a", "from": "", "detail": ""},
        "attributes": []
      },
      {
        "name": "spnl.pair.a.total", "signal": "metrics", "record": "u_187_xdp_emit_pair_pair_event",
        "span_name": "", "span_kind": "", "note": "",
        "timing": {"start": "record_ktime:hdr.timestamp", "clock": "monotonic", "end": "start"},
        "drop_when": {"op": "never"},
        "value": {"kind": "field", "name": "a", "from": "", "detail": ""},
        "metric": {"kind": "sum", "unit": "1", "temporality": "cumulative", "monotonic": true},
        "attributes": []
      },
      {
        "name": "spnl.pair.b.hist", "signal": "metrics", "record": "u_187_xdp_emit_pair_pair_event",
        "span_name": "", "span_kind": "", "note": "",
        "timing": {"start": "record_ktime:hdr.timestamp", "clock": "monotonic", "end": "start"},
        "drop_when": {"op": "never"},
        "value": {"kind": "field", "name": "b", "from": "", "detail": ""},
        "metric": {"kind": "exponential_histogram", "unit": "1", "temporality": "cumulative",
                   "scale": 0, "zero_threshold": 0, "bucket_rule": "otlp_lower_exclusive"},
        "attributes": []
      }
    ]
  },
  "extensions": {}
}`

const testRecordSymbol = "u_187_xdp_emit_pair_pair_event"

// pairRecordBytes は type=0x0102, version=1, reserved=0, timestamp=111222333,
// a=7, b=9 の 32B record を count 個連結したバイト列を作る。
func pairRecordBytes(t *testing.T, count int, timestamp uint64, a, b int64) []byte {
	t.Helper()
	rec := make([]byte, 32)
	binary.LittleEndian.PutUint16(rec[0:2], 0x0102)
	binary.LittleEndian.PutUint16(rec[2:4], 1)
	binary.LittleEndian.PutUint32(rec[4:8], 0)
	binary.LittleEndian.PutUint64(rec[8:16], timestamp)
	binary.LittleEndian.PutUint64(rec[16:24], uint64(a))
	binary.LittleEndian.PutUint64(rec[24:32], uint64(b))
	out := make([]byte, 0, 32*count)
	for i := 0; i < count; i++ {
		out = append(out, rec...)
	}
	return out
}

func mustParseSchema(t *testing.T) *schemaDoc {
	t.Helper()
	doc, err := parseSchema([]byte(testSchema))
	if err != nil {
		t.Fatalf("parseSchema: %v", err)
	}
	return doc
}

func TestBuildModel_LogsSumHistogram(t *testing.T) {
	doc := mustParseSchema(t)
	const wallOffset = int64(1_700_000_000_000_000_000)
	const timestamp = uint64(111222333)
	recBytes := pairRecordBytes(t, 3, timestamp, 7, 9)

	model, err := buildModel(doc, testRecordSymbol, recBytes, wallOffset)
	if err != nil {
		t.Fatalf("buildModel: %v", err)
	}

	// --- log_records: 3件、body int=7、time = timestamp + offset、順序保存 ---
	if len(model.LogRecords) != 3 {
		t.Fatalf("log_records count = %d, want 3", len(model.LogRecords))
	}
	wantTime := int64(timestamp) + wallOffset
	for i, lr := range model.LogRecords {
		if lr.Body.Int != 7 {
			t.Errorf("log_records[%d].body.int = %d, want 7", i, lr.Body.Int)
		}
		if lr.TimeUnixNano != wantTime {
			t.Errorf("log_records[%d].time_unix_nano = %d, want %d", i, lr.TimeUnixNano, wantTime)
		}
		if len(lr.Attributes) != 0 {
			t.Errorf("log_records[%d].attributes = %v, want empty", i, lr.Attributes)
		}
	}

	// --- sums: value=21, monotonic=true, temporality=cumulative ---
	if len(model.Sums) != 1 {
		t.Fatalf("sums count = %d, want 1", len(model.Sums))
	}
	sum := model.Sums[0]
	if sum.Name != "spnl.pair.a.total" {
		t.Errorf("sums[0].name = %q", sum.Name)
	}
	if !sum.IsMonotonic {
		t.Errorf("sums[0].is_monotonic = false, want true")
	}
	if sum.Temporality != "cumulative" {
		t.Errorf("sums[0].temporality = %q, want cumulative", sum.Temporality)
	}
	if len(sum.DataPoints) != 1 {
		t.Fatalf("sums[0].data_points count = %d, want 1", len(sum.DataPoints))
	}
	if sum.DataPoints[0].Value != 21 {
		t.Errorf("sums[0].data_points[0].value = %d, want 21", sum.DataPoints[0].Value)
	}
	if sum.DataPoints[0].StartTimeUnixNano != wantTime || sum.DataPoints[0].TimeUnixNano != wantTime {
		t.Errorf("sums[0].data_points[0] time = (%d,%d), want (%d,%d)",
			sum.DataPoints[0].StartTimeUnixNano, sum.DataPoints[0].TimeUnixNano, wantTime, wantTime)
	}

	// --- exponential_histograms: count=3, sum=27, zero_count=0, positive offset=3 counts=[3] ---
	if len(model.ExponentialHistograms) != 1 {
		t.Fatalf("exponential_histograms count = %d, want 1", len(model.ExponentialHistograms))
	}
	hist := model.ExponentialHistograms[0].DataPoints[0]
	if hist.Count != 3 {
		t.Errorf("hist.count = %d, want 3", hist.Count)
	}
	if hist.Sum != 27 {
		t.Errorf("hist.sum = %d, want 27", hist.Sum)
	}
	if hist.ZeroCount != 0 {
		t.Errorf("hist.zero_count = %d, want 0", hist.ZeroCount)
	}
	if hist.Positive.Offset != 3 {
		t.Errorf("hist.positive.offset = %d, want 3 (9 は (8,16])", hist.Positive.Offset)
	}
	if len(hist.Positive.BucketCounts) != 1 || hist.Positive.BucketCounts[0] != 3 {
		t.Errorf("hist.positive.bucket_counts = %v, want [3]", hist.Positive.BucketCounts)
	}
	if len(hist.Negative.BucketCounts) != 0 {
		t.Errorf("hist.negative.bucket_counts = %v, want []", hist.Negative.BucketCounts)
	}
}

func TestBuildModel_LengthMismatchRejected(t *testing.T) {
	doc := mustParseSchema(t)
	recBytes := pairRecordBytes(t, 3, 111222333, 7, 9)
	recBytes = append(recBytes, 0x00) // 33B: 32 の倍数でない

	_, err := buildModel(doc, testRecordSymbol, recBytes, 0)
	if err == nil {
		t.Fatal("length mismatch のはずが成功した")
	}
	if !strings.Contains(err.Error(), "length mismatch") && !strings.Contains(err.Error(), "multiple") {
		t.Errorf("error message が length mismatch を示していない: %v", err)
	}
}

func TestParseSchema_UnknownTelemetryKeyRejected(t *testing.T) {
	bad := strings.Replace(testSchema,
		`"name": "spnl.pair.log", "signal": "logs"`,
		`"name": "spnl.pair.log", "signal": "logs", "unknown_field": true`,
		1)
	if bad == testSchema {
		t.Fatal("test bug: 置換対象が見つからなかった")
	}
	_, err := parseSchema([]byte(bad))
	if err == nil {
		t.Fatal("未知 key があるのに parseSchema が成功した")
	}
}

func TestParseSchema_UnknownClockKeyRejected(t *testing.T) {
	bad := strings.Replace(testSchema,
		`"posix_clock": "CLOCK_MONOTONIC",`,
		`"posix_clock": "CLOCK_MONOTONIC", "unknown_field": true,`,
		1)
	if bad == testSchema {
		t.Fatal("test bug: 置換対象が見つからなかった")
	}
	_, err := parseSchema([]byte(bad))
	if err == nil {
		t.Fatal("未知 key があるのに parseSchema が成功した")
	}
}

func TestBuildModel_TracesSignalRejected(t *testing.T) {
	bad := strings.Replace(testSchema,
		`"name": "spnl.pair.log", "signal": "logs", "record": "u_187_xdp_emit_pair_pair_event",`,
		`"name": "spnl.pair.log", "signal": "traces", "record": "u_187_xdp_emit_pair_pair_event",`,
		1)
	doc, err := parseSchema([]byte(bad))
	if err != nil {
		t.Fatalf("parseSchema: %v", err)
	}
	recBytes := pairRecordBytes(t, 1, 111222333, 7, 9)
	if _, err := buildModel(doc, testRecordSymbol, recBytes, 0); err == nil {
		t.Fatal("signal traces があるのに buildModel が成功した")
	}
}

func TestBuildModel_UnknownRecordRejected(t *testing.T) {
	doc := mustParseSchema(t)
	recBytes := pairRecordBytes(t, 1, 111222333, 7, 9)
	if _, err := buildModel(doc, "no_such_record", recBytes, 0); err == nil {
		t.Fatal("存在しない record を指定したのに成功した")
	}
}
