/* spbpf_schema_adapter.h — codegen が下した宣言を構造化して記録する (E154 / P013 Task 7)。
 *
 * **これは新しい正典ではない。** 1 回の codegen 呼び出しの間だけ生きる
 * 「宣言 manifest」であり、map / record / program を決めた地点でそのまま登録する。
 * 生成された .bpf.c を読み直して表を作ることはしない。
 *
 * 所有: 呼び出しごとに spbpf_manifest_new / _free。プロセス全体に残る状態を持たない
 * (前回の宣言が次の呼び出しに混入しないことは test_mlir_shadow.rb が確かめる)。
 *
 * 出力を変えない: 登録は既存の emit 経路の**隣**で行い、buf_printf / tpl_emit には
 * 一切触れない。既定経路の .bpf.c は byte-identical である。
 */
#ifndef SPBPF_SCHEMA_ADAPTER_H
#define SPBPF_SCHEMA_ADAPTER_H

#include <stddef.h>

typedef enum {
  SPBPF_MAP_HASH = 0,
  SPBPF_MAP_ARRAY,
  SPBPF_MAP_PERCPU_ARRAY,
  SPBPF_MAP_LRU_HASH,
  SPBPF_MAP_RINGBUF,
} SpbpfMapKind;

typedef struct {
  char *name;
  char *ctype;   /* 宣言どおりの綴り ("__s64" / "char" ...) */
  int   count;   /* 0 = スカラ、>0 = 配列の要素数 */
} SpbpfField;

typedef struct {
  char *symbol;
  /* E155: channel の record ID (types.h の SPNL_EVT_* macro 名、綴りのまま)。
   * NULL = 未割当。数値への解決は include/spnl/types.h が単一ソースで、
   * 読む側 (spbpf_schema.rb) がそこから引く。 */
  char *evt_tag;
  SpbpfField *fields;
  int nfields;
} SpbpfRecord;

typedef struct {
  char *symbol;
  SpbpfMapKind kind;
  char *key;          /* NULL 可 (ringbuf) */
  char *value;        /* NULL 可 (ringbuf) */
  long long max_entries;
  char *record;       /* ringbuf が運ぶ record symbol。NULL 可 */
} SpbpfMap;

/* enforcement verdict の解析結果。**「分からない」を既定値へ倒さない**ため、
 * 4 状態を明示する (E154 / Mac の判断)。 */
typedef enum {
  SPBPF_VERDICT_NONE = 0,  /* verdict を持たない attach 種別 (観測型) */
  SPBPF_VERDICT_KNOWN,     /* 末尾が既知定数 */
  SPBPF_VERDICT_DYNAMIC,   /* 有効だが非定数 */
  SPBPF_VERDICT_UNKNOWN,   /* 解釈不能 — 後段で停止する */
} SpbpfVerdictState;

/* program body の解析結果 (E154 checkpoint 3)。verdict と同じ思想で、
 * **「分からない」を既定値へ倒さない**: 登録時は UNKNOWN で、分類器が body の
 * 全文を steps に写せたときだけ KNOWN へ上げる。UNKNOWN の program から
 * MLIR object を作ることはできない (後段が停止する)。 */
typedef enum {
  SPBPF_BODY_UNKNOWN = 0,  /* 分類できない文があった (登録時の既定) */
  SPBPF_BODY_KNOWN,        /* steps が body の全文 (verdict を除く) を写している */
} SpbpfBodyState;

/* body step。語彙は 2 つ (広げるときは MLIR 側 spbpf_schema.rb と対で広げる):
 *   map_rmw_add: lookup(key=0) -> (miss は 0) -> v1 を加算 -> update(key=0)
 *                — cc_emit_ivar_rmw が `@x = @x + k` に出す C と同じ意味
 *   emit_pair:   reserve -> hdr(4 field) + a(v1) + b(v2) -> submit /
 *                reserve 失敗は lost counter += 1 — spnl_emit_pair(a, b) の
 *                emit 経路と同じ意味 (E025 / E155) */
typedef struct {
  const char *op;   /* "map_rmw_add" | "emit_pair" (静的文字列 — free しない) */
  char *map;        /* 対象 map の symbol (登録済みの map であること) */
  long long v1, v2; /* rmw: (delta, 未使用) / emit_pair: (a, b) */
} SpbpfBodyStep;

typedef struct {
  char *name;
  char *sec;          /* SEC の綴りそのまま */
  char *kind;         /* attach 宣言表の kname */
  int   has_verdict;  /* enforcement 型か (宣言表の verdict) */
  SpbpfVerdictState verdict_state;
  long long verdict;
  SpbpfBodyState body_state;
  SpbpfBodyStep *steps; int nsteps;
} SpbpfProgram;

typedef struct {
  char *unit;
  SpbpfMap     *maps;     int nmaps;
  SpbpfRecord  *records;  int nrecords;
  SpbpfProgram *programs; int nprograms;
  /* **黙って欠落させない**: 登録できなかった宣言カテゴリをここに残す。 */
  char **unsupported;     int nunsupported;
  /* 重複 symbol 等、manifest を信用できなくする誤り。非 NULL なら JSON を出さない。 */
  char *error;
} SpbpfManifest;

SpbpfManifest *spbpf_manifest_new(const char *unit);
void spbpf_manifest_free(SpbpfManifest *m);

/* 0 = 登録できた / -1 = 拒否 (重複 symbol)。拒否は m->error にも残る。 */
int spbpf_manifest_add_map(SpbpfManifest *m, const char *symbol, SpbpfMapKind kind,
                           const char *key, const char *value,
                           long long max_entries, const char *record);
int spbpf_manifest_add_record(SpbpfManifest *m, const char *symbol);
int spbpf_manifest_add_field(SpbpfManifest *m, const char *record_symbol,
                             const char *name, const char *ctype, int count);
int spbpf_manifest_add_program(SpbpfManifest *m, const char *name, const char *sec,
                               const char *kind, int has_verdict);

/* program 登録後に verdict を書き入れる。
 * **存在しない program / has_verdict=false の program への更新は manifest error**。 */
int spbpf_manifest_set_program_verdict(SpbpfManifest *m, const char *name,
                                       SpbpfVerdictState state, long long value);

/* program body の step を積む (E154 checkpoint 3)。
 * 順序:
 *   1. add_body_step_rmw_add を body の文ごとに呼ぶ
 *   2. **全文を写せたときだけ** set_program_body_known で KNOWN へ上げる
 * 途中で 1 が失敗したら 2 を呼ばない — body は UNKNOWN のまま残り、
 * MLIR object の生成は後段で停止する (fail-safe)。
 *
 * add_body_step_rmw_add の戻り:
 *    0 = 積めた
 *   -1 (seterr なし) = map が manifest に登録されていない — 分類器の命名が
 *      実際の宣言とずれたときここで止まる。呼び手は body を UNKNOWN のまま残す。
 *   -1 (seterr あり) = 存在しない program への登録 (misuse)。 */
int spbpf_manifest_add_body_step_rmw_add(SpbpfManifest *m, const char *name,
                                         const char *map, long long delta);
/* emit_pair step (E155)。map は登録済みの ringbuf を指すこと (規約は
 * add_body_step_rmw_add と同じ)。 */
int spbpf_manifest_add_body_step_emit_pair(SpbpfManifest *m, const char *name,
                                           const char *map, long long a,
                                           long long b);
int spbpf_manifest_set_program_body_known(SpbpfManifest *m, const char *name);

/* record の evt_tag を後付けする (E155)。存在しない record は manifest error。 */
int spbpf_manifest_set_record_evt_tag(SpbpfManifest *m, const char *symbol,
                                      const char *evt_tag);

/* E154 の対象外だと分かっている宣言を明示的に残す。 */
void spbpf_manifest_note_unsupported(SpbpfManifest *m, const char *what);

/* caller が free する。m->error が立っていれば NULL。 */
char *spbpf_manifest_to_json(const SpbpfManifest *m);

/* --- in-process consumer 境界 (E154) -----------------------------------------
 *
 * codegen をライブラリとして呼ぶ側 (mlir backend) が manifest を受け取る口。
 * ファイル出力だけで終わらせない。
 *
 * spbpf_manifest_take_json:
 *   直前の codegen 呼び出しの manifest を JSON にして**所有権ごと渡す**。
 *   取り出した時点で内部の manifest は解放され、内部ポインタは NULL に戻る。
 *   caller が free する。manifest が無い / 信用できないときは NULL。
 *
 * spbpf_manifest_release:
 *   取り出さない場合の明示解放。**最後の呼び出しの後にも解放できる**ように
 *   置いてある (in-process では最後の manifest が残るため)。何度呼んでもよい。
 */
char *spbpf_manifest_take_json(void);
void spbpf_manifest_release(void);

#endif /* SPBPF_SCHEMA_ADAPTER_H */
