/* spbpf_schema_adapter.c — 宣言 manifest (E154 / P013 Task 7)。詳細は .h を参照。 */
#include "spbpf_schema_adapter.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *sdup(const char *s) { return s ? strdup(s) : NULL; }

static void seterr(SpbpfManifest *m, const char *fmt, const char *a) {
  if (m->error) return;                 /* 最初の誤りを残す */
  size_t n = strlen(fmt) + (a ? strlen(a) : 0) + 8;
  m->error = (char *)malloc(n);
  if (m->error) snprintf(m->error, n, fmt, a ? a : "");
}

SpbpfManifest *spbpf_manifest_new(const char *unit) {
  SpbpfManifest *m = (SpbpfManifest *)calloc(1, sizeof *m);
  if (!m) return NULL;
  m->unit = sdup(unit);
  return m;
}

void spbpf_manifest_free(SpbpfManifest *m) {
  if (!m) return;
  free(m->unit);
  for (int i = 0; i < m->nmaps; i++) {
    free(m->maps[i].symbol); free(m->maps[i].key);
    free(m->maps[i].value);  free(m->maps[i].record);
  }
  free(m->maps);
  for (int i = 0; i < m->nrecords; i++) {
    for (int j = 0; j < m->records[i].nfields; j++) {
      free(m->records[i].fields[j].name);
      free(m->records[i].fields[j].ctype);
    }
    free(m->records[i].fields);
    free(m->records[i].symbol);
    free(m->records[i].evt_tag);
  }
  free(m->records);
  for (int i = 0; i < m->nprograms; i++) {
    free(m->programs[i].name); free(m->programs[i].sec); free(m->programs[i].kind);
    for (int j = 0; j < m->programs[i].nsteps; j++) free(m->programs[i].steps[j].map);
    free(m->programs[i].steps);
  }
  free(m->programs);
  for (int i = 0; i < m->nunsupported; i++) free(m->unsupported[i]);
  free(m->unsupported);
  free(m->error);
  free(m);
}

/* --- 重複 symbol は登録時に拒否する (黙って上書きしない) -------------------- */
static int have_symbol(const SpbpfManifest *m, const char *s) {
  for (int i = 0; i < m->nmaps; i++)     if (!strcmp(m->maps[i].symbol, s)) return 1;
  for (int i = 0; i < m->nrecords; i++)  if (!strcmp(m->records[i].symbol, s)) return 1;
  for (int i = 0; i < m->nprograms; i++) if (!strcmp(m->programs[i].name, s)) return 1;
  return 0;
}

int spbpf_manifest_add_map(SpbpfManifest *m, const char *symbol, SpbpfMapKind kind,
                           const char *key, const char *value,
                           long long max_entries, const char *record) {
  if (!m || !symbol) return -1;
  if (have_symbol(m, symbol)) {
    seterr(m, "duplicate symbol registered in the manifest: %s", symbol);
    return -1;
  }
  SpbpfMap *n = (SpbpfMap *)realloc(m->maps, (size_t)(m->nmaps + 1) * sizeof *n);
  if (!n) return -1;
  m->maps = n;
  SpbpfMap *e = &m->maps[m->nmaps++];
  memset(e, 0, sizeof *e);
  e->symbol = sdup(symbol); e->kind = kind;
  e->key = sdup(key); e->value = sdup(value);
  e->max_entries = max_entries; e->record = sdup(record);
  return 0;
}

int spbpf_manifest_add_record(SpbpfManifest *m, const char *symbol) {
  if (!m || !symbol) return -1;
  if (have_symbol(m, symbol)) {
    seterr(m, "duplicate symbol registered in the manifest: %s", symbol);
    return -1;
  }
  SpbpfRecord *n = (SpbpfRecord *)realloc(m->records, (size_t)(m->nrecords + 1) * sizeof *n);
  if (!n) return -1;
  m->records = n;
  SpbpfRecord *e = &m->records[m->nrecords++];
  memset(e, 0, sizeof *e);
  e->symbol = sdup(symbol);
  return 0;
}

int spbpf_manifest_add_field(SpbpfManifest *m, const char *record_symbol,
                             const char *name, const char *ctype, int count) {
  if (!m || !record_symbol || !name) return -1;
  SpbpfRecord *r = NULL;
  for (int i = 0; i < m->nrecords; i++)
    if (!strcmp(m->records[i].symbol, record_symbol)) r = &m->records[i];
  if (!r) { seterr(m, "field registered for an unknown record: %s", record_symbol); return -1; }
  for (int j = 0; j < r->nfields; j++)
    if (!strcmp(r->fields[j].name, name)) {
      seterr(m, "duplicate field registered in a record: %s", name);
      return -1;
    }
  SpbpfField *n = (SpbpfField *)realloc(r->fields, (size_t)(r->nfields + 1) * sizeof *n);
  if (!n) return -1;
  r->fields = n;
  SpbpfField *e = &r->fields[r->nfields++];
  memset(e, 0, sizeof *e);
  e->name = sdup(name); e->ctype = sdup(ctype); e->count = count;
  return 0;
}

int spbpf_manifest_add_program(SpbpfManifest *m, const char *name, const char *sec,
                               const char *kind, int has_verdict) {
  if (!m || !name) return -1;
  if (have_symbol(m, name)) {
    seterr(m, "duplicate symbol registered in the manifest: %s", name);
    return -1;
  }
  SpbpfProgram *n = (SpbpfProgram *)realloc(m->programs, (size_t)(m->nprograms + 1) * sizeof *n);
  if (!n) return -1;
  m->programs = n;
  SpbpfProgram *e = &m->programs[m->nprograms++];
  memset(e, 0, sizeof *e);
  e->name = sdup(name); e->sec = sdup(sec); e->kind = sdup(kind);
  e->has_verdict = has_verdict;
  /* verdict は別途 set_program_verdict で入れる。enforcement 型なのに未設定の
   * ままなら UNKNOWN のまま残り、後段が停止する — 既定値へ倒さない。 */
  e->verdict_state = has_verdict ? SPBPF_VERDICT_UNKNOWN : SPBPF_VERDICT_NONE;
  e->verdict = 0;
  /* body も verdict と同じ: **既定は UNKNOWN**。分類器が全文を写せたときだけ
   * set_program_body_known が KNOWN へ上げる。 */
  e->body_state = SPBPF_BODY_UNKNOWN;
  e->steps = NULL; e->nsteps = 0;
  return 0;
}

static SpbpfProgram *find_program(SpbpfManifest *m, const char *name) {
  for (int i = 0; i < m->nprograms; i++)
    if (!strcmp(m->programs[i].name, name)) return &m->programs[i];
  return NULL;
}

static int add_body_step(SpbpfManifest *m, const char *name, const char *op,
                         const char *map, long long v1, long long v2) {
  if (!m || !name || !map) return -1;
  SpbpfProgram *p = find_program(m, name);
  if (!p) {
    seterr(m, "body step added for a program that is not in the manifest: %s", name);
    return -1;
  }
  /* map は**登録済みの宣言**を指していなければならない。分類器の命名規則が
   * 実際の map 宣言とずれたとき、ここで step を拒否して body を UNKNOWN の
   * まま残す (manifest error にはしない — 分類できないだけで、宣言 manifest
   * そのものは信用できる)。 */
  int found = 0;
  for (int i = 0; i < m->nmaps; i++)
    if (!strcmp(m->maps[i].symbol, map)) { found = 1; break; }
  if (!found) return -1;
  SpbpfBodyStep *n = (SpbpfBodyStep *)realloc(p->steps, (size_t)(p->nsteps + 1) * sizeof *n);
  if (!n) return -1;
  p->steps = n;
  SpbpfBodyStep *e = &p->steps[p->nsteps++];
  e->op = op; e->map = sdup(map); e->v1 = v1; e->v2 = v2;
  return 0;
}

int spbpf_manifest_add_body_step_rmw_add(SpbpfManifest *m, const char *name,
                                         const char *map, long long delta) {
  return add_body_step(m, name, "map_rmw_add", map, delta, 0);
}

int spbpf_manifest_add_body_step_emit_pair(SpbpfManifest *m, const char *name,
                                           const char *map, long long a,
                                           long long b) {
  return add_body_step(m, name, "emit_pair", map, a, b);
}

int spbpf_manifest_set_record_evt_tag(SpbpfManifest *m, const char *symbol,
                                      const char *evt_tag) {
  if (!m || !symbol || !evt_tag) return -1;
  for (int i = 0; i < m->nrecords; i++)
    if (!strcmp(m->records[i].symbol, symbol)) {
      free(m->records[i].evt_tag);
      m->records[i].evt_tag = sdup(evt_tag);
      return 0;
    }
  seterr(m, "evt_tag set for a record that is not in the manifest: %s", symbol);
  return -1;
}

int spbpf_manifest_set_program_body_known(SpbpfManifest *m, const char *name) {
  if (!m || !name) return -1;
  SpbpfProgram *p = find_program(m, name);
  if (!p) {
    seterr(m, "body marked known for a program that is not in the manifest: %s", name);
    return -1;
  }
  p->body_state = SPBPF_BODY_KNOWN;
  return 0;
}

int spbpf_manifest_set_program_verdict(SpbpfManifest *m, const char *name,
                                       SpbpfVerdictState state, long long value) {
  if (!m || !name) return -1;
  SpbpfProgram *p = NULL;
  for (int i = 0; i < m->nprograms; i++)
    if (!strcmp(m->programs[i].name, name)) p = &m->programs[i];
  if (!p) {
    seterr(m, "verdict set for a program that is not in the manifest: %s", name);
    return -1;
  }
  if (!p->has_verdict) {
    seterr(m, "verdict set for a program whose attach kind carries none: %s", name);
    return -1;
  }
  /* **enum 範囲外は受けない。** 未初期化や cast 事故が「既知の verdict」として
   * 通ると manifest が信用できなくなる (Mac の指摘 2026-08-25)。 */
  if (state != SPBPF_VERDICT_NONE && state != SPBPF_VERDICT_KNOWN &&
      state != SPBPF_VERDICT_DYNAMIC && state != SPBPF_VERDICT_UNKNOWN) {
    char what[160];
    snprintf(what, sizeof what, "%s (state=%d)", name, (int)state);
    seterr(m, "verdict state out of range for %s", what);
    return -1;
  }
  /* enforcement program に NONE は付けられない。NONE は「verdict を持たない
   * attach 種別」の意味であって、「今回は分からない」ではない — それは UNKNOWN。 */
  if (state == SPBPF_VERDICT_NONE) {
    seterr(m, "verdict NONE set on an enforcement program: %s "
              "(use UNKNOWN for an unresolved verdict)", name);
    return -1;
  }
  p->verdict_state = state;
  p->verdict = value;
  return 0;
}

void spbpf_manifest_note_unsupported(SpbpfManifest *m, const char *what) {
  if (!m || !what) return;
  for (int i = 0; i < m->nunsupported; i++)
    if (!strcmp(m->unsupported[i], what)) return;   /* 同じ理由は 1 度だけ */
  char **n = (char **)realloc(m->unsupported, (size_t)(m->nunsupported + 1) * sizeof *n);
  if (!n) return;
  m->unsupported = n;
  m->unsupported[m->nunsupported++] = sdup(what);
}

/* --- JSON ------------------------------------------------------------------ */
typedef struct { char *p; size_t len, cap; } J;

static void jput(J *j, const char *s) {
  size_t n = strlen(s);
  if (j->len + n + 1 > j->cap) {
    size_t c = j->cap ? j->cap * 2 : 512;
    while (c < j->len + n + 1) c *= 2;
    char *p = (char *)realloc(j->p, c);
    if (!p) return;
    j->p = p; j->cap = c;
  }
  memcpy(j->p + j->len, s, n);
  j->len += n;
  j->p[j->len] = 0;
}

static void jstr(J *j, const char *s) {
  jput(j, "\"");
  for (const char *p = s ? s : ""; *p; p++) {
    if (*p == '"' || *p == '\\') { char b[3] = { '\\', *p, 0 }; jput(j, b); }
    else if (*p == '\n') jput(j, "\\n");
    else { char b[2] = { *p, 0 }; jput(j, b); }
  }
  jput(j, "\"");
}

static void jnum(J *j, long long v) { char b[32]; snprintf(b, sizeof b, "%lld", v); jput(j, b); }

static const char *kind_name(SpbpfMapKind k) {
  switch (k) {
  case SPBPF_MAP_HASH: return "hash";
  case SPBPF_MAP_ARRAY: return "array";
  case SPBPF_MAP_PERCPU_ARRAY: return "percpu_array";
  case SPBPF_MAP_LRU_HASH: return "lru_hash";
  case SPBPF_MAP_RINGBUF: return "ringbuf";
  }
  return "unknown";
}

char *spbpf_manifest_to_json(const SpbpfManifest *m) {
  if (!m || m->error) return NULL;
  J j = {0};
  jput(&j, "{\n  \"unit\": "); jstr(&j, m->unit); jput(&j, ",\n");

  jput(&j, "  \"programs\": [");
  for (int i = 0; i < m->nprograms; i++) {
    const SpbpfProgram *p = &m->programs[i];
    jput(&j, i ? ",\n    {" : "\n    {");
    jput(&j, "\"name\": "); jstr(&j, p->name);
    jput(&j, ", \"sec\": "); jstr(&j, p->sec);
    jput(&j, ", \"kind\": "); jstr(&j, p->kind);
    jput(&j, ", \"has_verdict\": "); jput(&j, p->has_verdict ? "true" : "false");
    jput(&j, ", \"verdict\": ");
    switch (p->verdict_state) {
    case SPBPF_VERDICT_NONE:    jput(&j, "null"); break;
    case SPBPF_VERDICT_KNOWN:   jnum(&j, p->verdict); break;
    case SPBPF_VERDICT_DYNAMIC: jput(&j, "\"dynamic\""); break;
    case SPBPF_VERDICT_UNKNOWN: jput(&j, "\"unknown\""); break;
    }
    /* body: KNOWN のときだけ steps を出す。UNKNOWN の steps は「全文を写せて
     * いない」ので出さない — 部分的な step 列を本物の body と誤読させない。 */
    jput(&j, ", \"body\": {\"state\": ");
    jput(&j, p->body_state == SPBPF_BODY_KNOWN ? "\"known\"" : "\"unknown\"");
    if (p->body_state == SPBPF_BODY_KNOWN) {
      jput(&j, ", \"steps\": [");
      for (int k = 0; k < p->nsteps; k++) {
        const SpbpfBodyStep *st = &p->steps[k];
        jput(&j, k ? ", {" : "{");
        jput(&j, "\"op\": "); jstr(&j, st->op);
        jput(&j, ", \"map\": "); jstr(&j, st->map);
        if (!strcmp(st->op, "emit_pair")) {
          jput(&j, ", \"a\": "); jnum(&j, st->v1);
          jput(&j, ", \"b\": "); jnum(&j, st->v2);
        } else {
          jput(&j, ", \"delta\": "); jnum(&j, st->v1);
        }
        jput(&j, "}");
      }
      jput(&j, "]");
    }
    jput(&j, "}}");
  }
  jput(&j, m->nprograms ? "\n  ],\n" : "],\n");

  jput(&j, "  \"maps\": [");
  for (int i = 0; i < m->nmaps; i++) {
    const SpbpfMap *e = &m->maps[i];
    jput(&j, i ? ",\n    {" : "\n    {");
    jput(&j, "\"symbol\": "); jstr(&j, e->symbol);
    jput(&j, ", \"kind\": "); jstr(&j, kind_name(e->kind));
    jput(&j, ", \"key\": ");   if (e->key) jstr(&j, e->key); else jput(&j, "null");
    jput(&j, ", \"value\": "); if (e->value) jstr(&j, e->value); else jput(&j, "null");
    jput(&j, ", \"max_entries\": "); jnum(&j, e->max_entries);
    jput(&j, ", \"record\": ");  if (e->record) jstr(&j, e->record); else jput(&j, "null");
    jput(&j, "}");
  }
  jput(&j, m->nmaps ? "\n  ],\n" : "],\n");

  jput(&j, "  \"records\": [");
  for (int i = 0; i < m->nrecords; i++) {
    const SpbpfRecord *r = &m->records[i];
    jput(&j, i ? ",\n    {" : "\n    {");
    jput(&j, "\"symbol\": "); jstr(&j, r->symbol);
    jput(&j, ", \"evt_tag\": ");
    if (r->evt_tag) jstr(&j, r->evt_tag); else jput(&j, "null");
    jput(&j, ", \"fields\": [");
    for (int k = 0; k < r->nfields; k++) {
      jput(&j, k ? ", {" : "{");
      jput(&j, "\"name\": "); jstr(&j, r->fields[k].name);
      jput(&j, ", \"ctype\": "); jstr(&j, r->fields[k].ctype);
      jput(&j, ", \"count\": "); jnum(&j, r->fields[k].count);
      jput(&j, "}");
    }
    jput(&j, "]}");
  }
  jput(&j, m->nrecords ? "\n  ],\n" : "],\n");

  jput(&j, "  \"unsupported\": [");
  for (int i = 0; i < m->nunsupported; i++) {
    if (i) jput(&j, ", ");
    jstr(&j, m->unsupported[i]);
  }
  jput(&j, "]\n}\n");
  return j.p;
}
