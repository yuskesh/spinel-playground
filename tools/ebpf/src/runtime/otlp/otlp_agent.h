/*
 * otlp_agent.h — `--instrument` agent から OTLP metrics を push する橋渡し (ADR-012 / P003 S2)
 *
 * spinel-Ruby の agent は配列を C へ渡せないので、メソッドを 1 件ずつ FFI で register し
 * (spnl_otlp_add_method)、push 時に C 側が bpf_hist_keyed を読んで OTLP 化 + POST する。
 * skel 型に依存しない(bpf_object* は glue shim が _spnl_skel->obj から渡す)。
 */
#ifndef SPNL_OTLP_AGENT_H
#define SPNL_OTLP_AGENT_H

struct bpf_object;

#ifdef __cplusplus
extern "C" {
#endif

/* Resource 属性 (service.name / service.version)。FFI: [:str,:str] -> :int */
int spnl_otlp_set_service(const char *name, const char *version);

/* 計装メソッドを 1 件 register (idx = bpf_hist_keyed の key)。ruby/file は内部コピー。
 * FFI: [:str,:str,:long,:long] -> :int */
int spnl_otlp_add_method(const char *ruby, const char *file, long long line, long long idx);

/* register 済の全メソッドについて obj から count/buckets を読み、OTLP を組んで endpoint へ POST。
 * HTTP ステータスを返す (転送失敗は <0)。glue shim 経由で呼ばれる。 */
int spnl_otlp_push_obj(struct bpf_object *obj, const char *map_name, const char *endpoint);

/* P003 S3: emit4 ringbuf (map_name) から enter/exit イベントを drain し、span を組み立てて
 * OTLP traces を endpoint へ POST。HTTP ステータスを返す。glue shim 経由で呼ばれる。 */
int spnl_otlp_trace_push_obj(struct bpf_object *obj, const char *map_name, const char *endpoint);

/* P003 S4: emit ringbuf (map_name) を drain し、各イベントを LogRecord にして OTLP logs を
 * endpoint へ POST。is_str!=0 なら str ringbuf (body=string)、0 なら int ringbuf (body=int)。 */
int spnl_otlp_log_push_obj(struct bpf_object *obj, const char *map_name, int is_str,
                           const char *endpoint);

/* S4/E371: 型付き consumer (`on_emit :dns do |ev| ... end`) の 3 語。簡潔形
 * spnl_otlp_dns_span_push_obj が 1 語に潰していた drain/to_span/send を分解したもので、
 * span の組み立ては同じ builder を通る (属性・SpanKind・時刻は両形式で同一)。
 *
 *   drain   -- ringbuf を読み record 数を返す。Ruby が持つ handle は 0..n-1 の index で、
 *              フィールドは生成 accessor (spnl_rec_dns_*、record_mirror_gen.h) 越しに読む。
 *   to_span -- 1 record を egress 宣言どおりの span に組む。0 = span にならない record。
 *   send    -- span を送信バッチに積む (0 handle は no-op)。flush はサイクル末尾で 1 POST。
 *
 * drain だけ map 名が要るので glue shim 経由 (他はプロセス内 state で完結)。 */
int spnl_rec_dns_drain_obj(struct bpf_object *obj, const char *map_name, int timeout_ms);
int spnl_rec_dns_to_span(int i);
/* E374 (ADR-017 D4): the same three words per opted-in channel. send/flush stay
 * channel-agnostic — one program may consume several channels and their spans all
 * go through one batch (`to_span` resolves the channel at compile time, ADR-017 D3). */
int spnl_rec_l7_drain_obj(struct bpf_object *obj, const char *map_name, int timeout_ms);
int spnl_rec_l7_to_span(int i);
int spnl_rec_http_drain_obj(struct bpf_object *obj, const char *map_name, int timeout_ms);
int spnl_rec_http_to_span(int i);
/* E375: conn。宛先 (`ev.peer`) は family を見て v4/v6 を選ぶ = record 全体を見る
 * derivation なので、3 つ目の impl_form (record_to_str) が入るまで据え置かれていた。 */
int spnl_rec_conn_drain_obj(struct bpf_object *obj, const char *map_name, int timeout_ms);
int spnl_rec_conn_to_span(int i);
int spnl_otlp_span_send(int handle, const char *endpoint);
int spnl_otlp_span_flush(void);

#ifdef __cplusplus
}
#endif

#endif /* SPNL_OTLP_AGENT_H */
