/* E154: 宣言 manifest の寿命を **1 プロセスの中で** 確かめる harness。
 *
 * Ruby 側のテストは spinel_ebpf_cc を 2 回「起動」しており、別プロセスなので
 * in-process の static 状態の混入を検査できていなかった (Mac 検収の指摘)。
 * ここは同じプロセスで ebpf_codegen_program を 2 回通す。
 *
 *   cc -DSPNL_EBPF_CC_NO_MAIN spinel_ebpf_cc.c spbpf_schema_adapter.c \
 *      tests/codegen_c/manifest_lifecycle.c -o manifest_lifecycle
 *   ./manifest_lifecycle <fixtures_dir>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "spbpf_schema_adapter.h"

char *spbpf_test_codegen_file(const char *ir, const char *ast, const char *base);

static int failures = 0;

static void ok(int cond, const char *what) {
  printf("%s %s\n", cond ? "ok  " : "FAIL", what);
  if (!cond) failures++;
}

static char *gen(const char *dir, const char *fixture) {
  char ir[512], ast[512], base[256];
  snprintf(ir, sizeof ir, "%s/%s.ir", dir, fixture);
  snprintf(ast, sizeof ast, "%s/%s.ast", dir, fixture);
  snprintf(base, sizeof base, "u_%s", fixture);
  return spbpf_test_codegen_file(ir, ast, base);
}

int main(int argc, char **argv) {
  const char *dir = argc > 1 ? argv[1] : "tests/fixtures";

  /* --- 1 回目 --- */
  char *src1 = gen(dir, "24_xdp_counter");
  ok(src1 && strstr(src1, "SEC(\"xdp\")") != NULL, "1 回目の生成が出た");
  char *m1 = spbpf_manifest_take_json();
  ok(m1 != NULL, "1 回目の manifest を取り出せた");
  ok(m1 && strstr(m1, "u_24_xdp_counter_top_rx_pkts") != NULL,
     "1 回目の manifest に自分の map が居る");
  ok(m1 && strstr(m1, "pair_event") == NULL,
     "1 回目の manifest に 2 回目の宣言が居ない");

  /* take したので内部は解放済み。**2 度目の take は NULL** であること。 */
  char *again = spbpf_manifest_take_json();
  ok(again == NULL, "take のあと内部ポインタが NULL に戻っている");
  free(again);

  /* --- 2 回目 (同じプロセス) --- */
  char *src2 = gen(dir, "22_emit_pair");
  ok(src2 && strstr(src2, "SEC(\"tracepoint/sched/sched_switch\")") != NULL,
     "2 回目の生成が出た");
  char *m2 = spbpf_manifest_take_json();
  ok(m2 != NULL, "2 回目の manifest を取り出せた");
  ok(m2 && strstr(m2, "u_22_emit_pair_pair_event") != NULL,
     "2 回目の manifest に自分の record が居る");
  /* **ここが本題**: 1 回目の宣言が残っていないこと。 */
  ok(m2 && strstr(m2, "24_xdp_counter") == NULL,
     "2 回目の manifest に 1 回目の宣言が混入していない");
  ok(m2 && strstr(m2, "u_22_emit_pair") != NULL, "2 回目の unit 名になっている");

  /* --- 3 回目: take せずに次を回しても前回が残らない --- */
  char *src3 = gen(dir, "24_xdp_counter");
  free(src3);
  char *src4 = gen(dir, "22_emit_pair");   /* take しないまま次へ */
  char *m4 = spbpf_manifest_take_json();
  ok(m4 && strstr(m4, "24_xdp_counter") == NULL,
     "take し忘れても次の呼び出しで前回分が解放されている");

  /* --- 最後の呼び出しの後に明示解放できること --- */
  char *src5 = gen(dir, "24_xdp_counter");
  spbpf_manifest_release();
  char *m5 = spbpf_manifest_take_json();
  ok(m5 == NULL, "release のあとは manifest が残らない");
  spbpf_manifest_release();   /* 二重 release が安全であること */
  ok(1, "二重 release で落ちない");

  free(src1); free(src2); free(src4); free(src5);
  free(m1); free(m2); free(m4); free(m5);

  /* --- verdict 更新の拒否 (E154) --- */
  {
    SpbpfManifest *m = spbpf_manifest_new("u_probe");
    spbpf_manifest_add_program(m, "xdp__p", "xdp", "xdp", /*has_verdict=*/1);
    spbpf_manifest_add_program(m, "tp__q", "tracepoint/x/y", "tracepoint", 0);

    ok(spbpf_manifest_set_program_verdict(m, "xdp__p", SPBPF_VERDICT_KNOWN, 2) == 0,
       "enforcement 型の verdict は書ける");
    ok(m->error == NULL, "正常な更新では error が立たない");

    /* **存在しない program への更新は error** */
    ok(spbpf_manifest_set_program_verdict(m, "nosuch", SPBPF_VERDICT_KNOWN, 2) == -1,
       "存在しない program への verdict 更新を拒否する");
    ok(m->error != NULL, "拒否が manifest error に残る");
    ok(spbpf_manifest_to_json(m) == NULL,
       "error のある manifest は JSON を出さない");
    spbpf_manifest_free(m);
  }
  {
    SpbpfManifest *m = spbpf_manifest_new("u_probe2");
    spbpf_manifest_add_program(m, "tp__q", "tracepoint/x/y", "tracepoint", /*has_verdict=*/0);
    /* **verdict を持たない種別への更新も error** */
    ok(spbpf_manifest_set_program_verdict(m, "tp__q", SPBPF_VERDICT_KNOWN, 0) == -1,
       "観測型 program への verdict 更新を拒否する");
    ok(m->error != NULL, "その拒否も manifest error に残る");
    spbpf_manifest_free(m);
  }

  /* **enforcement program に NONE は付けられない** (Mac の指摘 2026-08-25)。
   * NONE は「verdict を持たない attach 種別」の意味であって「今回は分からない」
   * ではない — 後者は UNKNOWN。取り違えると、解決できなかった verdict が
   * 観測型と同じ「比較不要」の側へ黙って落ちる。 */
  {
    SpbpfManifest *m = spbpf_manifest_new("u_probe3");
    spbpf_manifest_add_program(m, "xdp__p", "xdp", "xdp", /*has_verdict=*/1);
    ok(spbpf_manifest_set_program_verdict(m, "xdp__p", SPBPF_VERDICT_NONE, 0) == -1,
       "enforcement program への NONE を拒否する");
    ok(m->error != NULL, "NONE の拒否が manifest error に残る");
    spbpf_manifest_free(m);
  }
  /* **enum 範囲外の state も拒否する。** 未初期化や cast 事故が
   * 「既知の verdict」として通ると manifest が信用できなくなる。 */
  {
    SpbpfManifest *m = spbpf_manifest_new("u_probe4");
    spbpf_manifest_add_program(m, "xdp__p", "xdp", "xdp", /*has_verdict=*/1);
    ok(spbpf_manifest_set_program_verdict(m, "xdp__p", (SpbpfVerdictState)99, 2) == -1,
       "enum 範囲外の verdict state を拒否する");
    ok(m->error != NULL, "範囲外 state の拒否が manifest error に残る");
    spbpf_manifest_free(m);
  }
  /* UNKNOWN は正当な状態なので通ること (範囲チェックが広すぎないことの対照)。 */
  {
    SpbpfManifest *m = spbpf_manifest_new("u_probe5");
    spbpf_manifest_add_program(m, "xdp__p", "xdp", "xdp", /*has_verdict=*/1);
    ok(spbpf_manifest_set_program_verdict(m, "xdp__p", SPBPF_VERDICT_UNKNOWN, 0) == 0,
       "UNKNOWN は enforcement program に書ける");
    ok(m->error == NULL, "UNKNOWN で error が立たない");
    spbpf_manifest_free(m);
  }

  /* --- program body (E154 checkpoint 3) --------------------------------- */
  /* 既定は UNKNOWN: 分類器が呼ばれなかった program の body を known と
   * 言わないこと。 */
  {
    SpbpfManifest *m = spbpf_manifest_new("u_body0");
    spbpf_manifest_add_program(m, "xdp__p", "xdp", "xdp", 1);
    spbpf_manifest_set_program_verdict(m, "xdp__p", SPBPF_VERDICT_KNOWN, 2);
    char *j = spbpf_manifest_to_json(m);
    ok(j && strstr(j, "\"body\": {\"state\": \"unknown\"}") != NULL,
       "body の既定は unknown として JSON に出る");
    free(j);
    spbpf_manifest_free(m);
  }
  /* step を積んで known へ上げる正常経路。 */
  {
    SpbpfManifest *m = spbpf_manifest_new("u_body1");
    spbpf_manifest_add_map(m, "u_body1_top_c", SPBPF_MAP_HASH, "__u32", "__s64", 1, NULL);
    spbpf_manifest_add_program(m, "xdp__p", "xdp", "xdp", 1);
    spbpf_manifest_set_program_verdict(m, "xdp__p", SPBPF_VERDICT_KNOWN, 2);
    ok(spbpf_manifest_add_body_step_rmw_add(m, "xdp__p", "u_body1_top_c", 1) == 0,
       "登録済み map への step は積める");
    ok(spbpf_manifest_set_program_body_known(m, "xdp__p") == 0, "body を known へ上げられる");
    char *j = spbpf_manifest_to_json(m);
    ok(j && strstr(j, "\"state\": \"known\"") != NULL, "known が JSON に出る");
    ok(j && strstr(j, "\"op\": \"map_rmw_add\", \"map\": \"u_body1_top_c\", \"delta\": 1") != NULL,
       "step が JSON に出る");
    free(j);
    spbpf_manifest_free(m);
  }
  /* 未登録 map への step は拒否され、**manifest error にはならない** (分類器の
   * 命名ずれは「分類できない」であって、宣言 manifest の破損ではない)。 */
  {
    SpbpfManifest *m = spbpf_manifest_new("u_body2");
    spbpf_manifest_add_program(m, "xdp__p", "xdp", "xdp", 1);
    spbpf_manifest_set_program_verdict(m, "xdp__p", SPBPF_VERDICT_KNOWN, 2);
    ok(spbpf_manifest_add_body_step_rmw_add(m, "xdp__p", "no_such_map", 1) == -1,
       "未登録 map への step は拒否される");
    ok(m->error == NULL, "その拒否は manifest error にしない");
    char *j = spbpf_manifest_to_json(m);
    ok(j && strstr(j, "\"state\": \"unknown\"") != NULL,
       "step を拒否された body は unknown のまま");
    free(j);
    spbpf_manifest_free(m);
  }
  /* 存在しない program への body 操作は misuse — manifest error。 */
  {
    SpbpfManifest *m = spbpf_manifest_new("u_body3");
    spbpf_manifest_add_map(m, "u_body3_top_c", SPBPF_MAP_HASH, "__u32", "__s64", 1, NULL);
    ok(spbpf_manifest_add_body_step_rmw_add(m, "nosuch", "u_body3_top_c", 1) == -1,
       "存在しない program への step は拒否される");
    ok(m->error != NULL, "その拒否は manifest error に残る");
    spbpf_manifest_free(m);
  }
  {
    SpbpfManifest *m = spbpf_manifest_new("u_body4");
    ok(spbpf_manifest_set_program_body_known(m, "nosuch") == -1,
       "存在しない program の body は known にできない");
    ok(m->error != NULL, "その拒否も manifest error に残る");
    spbpf_manifest_free(m);
  }

  /* --- emit_pair step と record evt_tag (E155) --------------------------- */
  {
    SpbpfManifest *m = spbpf_manifest_new("u_ep1");
    spbpf_manifest_add_map(m, "u_ep1_pair_events", SPBPF_MAP_RINGBUF, NULL, NULL,
                           256 * 1024, "u_ep1_pair_event");
    spbpf_manifest_add_record(m, "u_ep1_pair_event");
    ok(spbpf_manifest_set_record_evt_tag(m, "u_ep1_pair_event", "SPNL_EVT_EMIT_PAIR") == 0,
       "record に evt_tag を書ける");
    spbpf_manifest_add_program(m, "xdp__p", "xdp", "xdp", 1);
    spbpf_manifest_set_program_verdict(m, "xdp__p", SPBPF_VERDICT_KNOWN, 2);
    ok(spbpf_manifest_add_body_step_emit_pair(m, "xdp__p", "u_ep1_pair_events", 7, 9) == 0,
       "登録済み ringbuf への emit_pair step は積める");
    spbpf_manifest_set_program_body_known(m, "xdp__p");
    char *j = spbpf_manifest_to_json(m);
    ok(j && strstr(j, "\"op\": \"emit_pair\", \"map\": \"u_ep1_pair_events\", \"a\": 7, \"b\": 9") != NULL,
       "emit_pair step が JSON に出る");
    ok(j && strstr(j, "\"evt_tag\": \"SPNL_EVT_EMIT_PAIR\"") != NULL,
       "evt_tag が JSON に出る");
    free(j);
    spbpf_manifest_free(m);
  }
  /* evt_tag を未登録 record へ書くのは misuse — manifest error。 */
  {
    SpbpfManifest *m = spbpf_manifest_new("u_ep2");
    ok(spbpf_manifest_set_record_evt_tag(m, "nosuch", "SPNL_EVT_EMIT_PAIR") == -1,
       "存在しない record への evt_tag は拒否される");
    ok(m->error != NULL, "その拒否は manifest error に残る");
    spbpf_manifest_free(m);
  }
  /* emit_pair step も未登録 map なら拒否 -> body は UNKNOWN のまま (rmw と同じ規約)。 */
  {
    SpbpfManifest *m = spbpf_manifest_new("u_ep3");
    spbpf_manifest_add_program(m, "xdp__p", "xdp", "xdp", 1);
    spbpf_manifest_set_program_verdict(m, "xdp__p", SPBPF_VERDICT_KNOWN, 2);
    ok(spbpf_manifest_add_body_step_emit_pair(m, "xdp__p", "no_such_rb", 1, 2) == -1,
       "未登録 ringbuf への emit_pair step は拒否される");
    ok(m->error == NULL, "その拒否は manifest error にしない");
    spbpf_manifest_free(m);
  }

  printf("\nmanifest-lifecycle: %s\n", failures ? "FAIL" : "all ok");
  return failures ? 1 : 0;
}
