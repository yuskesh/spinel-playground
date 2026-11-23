/*
 * otlp_pbutil.h — OTLP encoder 共通 nanopb ヘルパ (ADR-012 / P003 R1, E263 G1)
 *
 * metrics/traces/logs の 3 encoder で重複していた scalar/属性/envelope の callback を集約する
 * (E263 D1)。すべて `static inline` なので、使わない TU で -Wunused-function は出ない。
 * signal 固有の struct 構築 (Sum/ExpHist/Span/LogRecord) は各 encoder 側に残す (本質差異)。
 */
#ifndef SPNL_OTLP_PBUTIL_H
#define SPNL_OTLP_PBUTIL_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>   /* getenv (E402: OTEL_RESOURCE_ATTRIBUTES) */
#include <string.h>

#include <pb_encode.h>
#include "opentelemetry/proto/common/v1/common.pb.h"
#include "otlp_http.h"  /* otlp_service_instance_id (E272 resource 属性) */

/* 文字列フィールド callback (arg = const char*) */
static inline bool otlp_enc_string(pb_ostream_t *st, const pb_field_iter_t *fld, void *const *arg) {
    const char *s = (const char *)(*arg);
    if (!pb_encode_tag_for_field(st, fld)) return false;
    return pb_encode_string(st, (const pb_byte_t *)s, strlen(s));
}

/* bytes フィールド callback (arg = otlp_bytes_t*) */
typedef struct { const uint8_t *p; size_t n; } otlp_bytes_t;
static inline bool otlp_enc_bytes(pb_ostream_t *st, const pb_field_iter_t *fld, void *const *arg) {
    const otlp_bytes_t *b = (const otlp_bytes_t *)(*arg);
    if (!pb_encode_tag_for_field(st, fld)) return false;
    return pb_encode_string(st, (const pb_byte_t *)b->p, b->n);
}

/* 「ちょうど 1 個の submessage を書く」汎用 callback (arg = otlp_one_sub_t*)。
 * ResourceX / ScopeX を 1 個だけ持つ repeated フィールド (resource_metrics/scope_metrics 等) 用。 */
typedef struct { const pb_msgdesc_t *fields; const void *msg; } otlp_one_sub_t;
static inline bool otlp_enc_one_sub(pb_ostream_t *st, const pb_field_iter_t *fld, void *const *arg) {
    const otlp_one_sub_t *o = (const otlp_one_sub_t *)(*arg);
    if (!pb_encode_tag_for_field(st, fld)) return false;
    return pb_encode_submessage(st, o->fields, o->msg);
}

/* attributes (repeated KeyValue) フィールドに 1 個の KeyValue{string} を書く */
static inline bool otlp_put_kv_str(pb_ostream_t *st, const pb_field_iter_t *fld,
                                   const char *key, const char *val) {
    opentelemetry_proto_common_v1_KeyValue kv = opentelemetry_proto_common_v1_KeyValue_init_zero;
    kv.key.funcs.encode = otlp_enc_string; kv.key.arg = (void *)key;
    kv.has_value = true;
    kv.value.which_value = opentelemetry_proto_common_v1_AnyValue_string_value_tag;
    kv.value.value.string_value.funcs.encode = otlp_enc_string;
    kv.value.value.string_value.arg = (void *)val;
    if (!pb_encode_tag_for_field(st, fld)) return false;
    return pb_encode_submessage(st, opentelemetry_proto_common_v1_KeyValue_fields, &kv);
}

/* attributes フィールドに 1 個の KeyValue{int} を書く */
static inline bool otlp_put_kv_int(pb_ostream_t *st, const pb_field_iter_t *fld,
                                   const char *key, int64_t val) {
    opentelemetry_proto_common_v1_KeyValue kv = opentelemetry_proto_common_v1_KeyValue_init_zero;
    kv.key.funcs.encode = otlp_enc_string; kv.key.arg = (void *)key;
    kv.has_value = true;
    kv.value.which_value = opentelemetry_proto_common_v1_AnyValue_int_value_tag;
    kv.value.value.int_value = val;
    if (!pb_encode_tag_for_field(st, fld)) return false;
    return pb_encode_submessage(st, opentelemetry_proto_common_v1_KeyValue_fields, &kv);
}

/*
 * Resource.attributes callback。arg = otlp_resource_t*。
 * service.name (+ service.version) に加えて OBI/semconv v1.41.0 互換の共通属性を全シグナルに
 * 乗せる (E272): service.instance.id / telemetry.sdk.{name,language,version}。
 * (OBI は service.version を出さないが、こちらは既存挙動を維持して出し続ける — divergence)。
 */
typedef struct { const char *name; const char *version; } otlp_resource_t;

static inline bool otlp_enc_resource_attrs(pb_ostream_t *st, const pb_field_iter_t *fld, void *const *arg) {
    const otlp_resource_t *r = (const otlp_resource_t *)(*arg);
    if (r->name && r->name[0] && !otlp_put_kv_str(st, fld, "service.name", r->name)) return false;
    if (r->version && r->version[0] && !otlp_put_kv_str(st, fld, "service.version", r->version)) return false;
    if (!otlp_put_kv_str(st, fld, "service.instance.id", otlp_service_instance_id())) return false;
    if (!otlp_put_kv_str(st, fld, "telemetry.sdk.name", "spinel-ebpf")) return false;
    if (!otlp_put_kv_str(st, fld, "telemetry.sdk.language", "ruby")) return false;
    if (!otlp_put_kv_str(st, fld, "telemetry.sdk.version", "0")) return false;
    /* E402 (D3): the operator's own labels, LAST -- so that a label cannot
     * silently shadow service.name / telemetry.sdk.*, and "who produced this"
     * stays answerable no matter what got set. Shape only is enforced (the
     * shared parser); the content is the operator's assertion, and this file is
     * in no position to check it -- which is precisely why it has to be theirs
     * and not the source's `# @intent` comment. */
    otlp_kv_t ra[OTLP_ENV_RESOURCE_ATTRS_MAX];
    int nra = otlp_env_kv_list("OTEL_RESOURCE_ATTRIBUTES", ra, OTLP_ENV_RESOURCE_ATTRS_MAX);
    for (int i = 0; i < nra; i++)
        if (!otlp_put_kv_str(st, fld, ra[i].key, ra[i].val)) return false;
    return true;
}

#endif /* SPNL_OTLP_PBUTIL_H */
