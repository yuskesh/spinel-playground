/* SPDX-License-Identifier: GPL-2.0
 *
 * amp_otlp.h — A55 側 drain: 共有リング (spnl/amp_ring.h) の ADR-002 レコードを
 * OTLP logs (LogRecord) に変換 (P007 S1)。既存 otlp_logs_build を再利用し、
 * amp_emit で出たイベントを A55 の OTLP スタックにそのまま流す。
 */
#ifndef SPNL_AMP_OTLP_H
#define SPNL_AMP_OTLP_H

#include <stdint.h>
#include <stddef.h>

struct amp_ring;

#ifdef __cplusplus
extern "C" {
#endif

/* Drain up to `max` unread records from `r` (advances r->cons) and build one
 * OTLP ExportLogsServiceRequest into `buf`. Each record -> 1 LogRecord
 * (body_int = value, time = hdr.timestamp). Returns encoded byte length (>=0)
 * or -1 on build failure; *n_drained gets the record count. If no records are
 * pending, returns 0 and *n_drained = 0 (no payload). */
long amp_ring_drain_logs(struct amp_ring *r, uint8_t *buf, size_t cap,
                         const char *service, const char *version,
                         size_t max, size_t *n_drained);

/* E357 (P007 S5): drain the ring into an OTLP *trace* correlated to an A55
 * request span. The request (its trace_id/span_id + PHC window [start,end]) is
 * the parent; each drained record whose hdr.timestamp (NETC PHC, gPTP-synced)
 * falls inside the window becomes a CHILD span of it, else a standalone root
 * (E312 in-window/fallback semantics). Cross-core correlation on one time axis.
 *   req_trace_id[16] / req_span_id[8]: the A55 span this M7 activity belongs to.
 *   req_start_ns / req_end_ns: PHC window (same clock as record timestamps).
 * Returns encoded byte length (>=0) or -1; *n_children = in-window records. */
long amp_ring_drain_trace(struct amp_ring *r,
                          const uint8_t req_trace_id[16], const uint8_t req_span_id[8],
                          uint64_t req_start_ns, uint64_t req_end_ns, const char *req_name,
                          uint8_t *buf, size_t cap, const char *service, const char *version,
                          uint64_t seed, size_t *n_children);

#ifdef __cplusplus
}
#endif

#endif /* SPNL_AMP_OTLP_H */
