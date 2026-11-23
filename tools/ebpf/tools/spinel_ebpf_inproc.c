/* ADR-011 Stage 2 in-process codegen driver (E237): emit the eBPF .bpf.c / the
 * SPINEL-IR v1 .ir for a .rb via the IN-PROCESS path — parse + analyze the
 * program to an upstream Compiler, then call spnl_ebpf_codegen_str
 * (fill_ir_from_compiler -> emitter) and/or cc_build_ir_text, with NO text
 * round-trip and NO `--emit-ir`. This is the production replacement for the
 * `build/spinel --emit-ir` + Stage-1 text codegen chain; tools/stage2_verify.sh
 * diffs its output against that chain to prove byte-identity over every fixture.
 *
 * Builds by #include-ing the codegen TU with SPNL_INPROCESS (so the text
 * parsers/main drop out and the Compiler-direct entry compiles in), then links
 * the upstream compiler objects (minus main.o) + the parse lib:
 *
 *   cc -DSPNL_INPROCESS -I third_party/spinel/src \
 *      tools/spinel_ebpf_inproc.c <spinel objs minus main.o> \
 *      third_party/spinel/build/libprism.a -lm -o build/codegen_c/spinel-ebpf-cc
 */
#define SPNL_INPROCESS
#include "../src/codegen_c/spinel_ebpf_cc.c"
#include "../../contract/spinel_nt_copy.h"   /* slc_nt_copy */

/* upstream entry points (declared here to avoid extra include-path coupling). */
NodeTable *sp_parse_file(const char *source_file, const char *argv0);
void  analyze_program(Compiler *c);

/* usage: spinel-ebpf-cc <file.rb> <base> [--ir]
 *   default : print the in-process .bpf.c (fill_ir_from_compiler -> emitter)
 *   --ir    : print the relocated SPINEL-IR v1 text (cc_build_ir_text), to diff
 *             against `build/spinel --emit-ir` (proves Patch A can be removed). */
int main(int argc, char **argv) {
  if (argc < 3 || argc > 4) { fprintf(stderr, "usage: %s <file.rb> <base> [--ir]\n", argv[0]); return 1; }
  int want_ir = (argc == 4 && !strcmp(argv[3], "--ir"));
  /* Two tables of the same parse: nt_ast stays pristine for the codegen's AST
   * reads; nt_an is mutated by analyze_program (block-param alpha-rename).
   * nt_an is an id-preserving copy of nt_ast (tools/contract/spinel_nt_copy.h),
   * so the Compiler's body_id/node refs index correctly into the pristine AST.
   * One parse: a second one in this process would see the files the first
   * spliced as already included. The .ir is built from the analyzed compiler
   * (matching upstream build_ir_text, which also runs post-analyze). */
  /* Spinel Extended: no builtins/ splice, as in the contract reader
   * (slc_disable_builtins). Upstream looks for builtins/ beside the running
   * executable and exits when it is absent, which it is beside this binary;
   * the pin skipped the splice silently. The .ast side (`spinel --dump-ast`,
   * run with the same variable) must number its nodes the same way. */
  setenv("SPINEL_NO_BUILTINS", "1", 1);
  NodeTable *nt_ast = sp_parse_file(argv[1], argv[0]);
  if (!nt_ast) { fprintf(stderr, "stage2_verify: parse failed for '%s'\n", argv[1]); return 1; }
  NodeTable *nt_an = slc_nt_copy(nt_ast);
  if (!nt_an) { fprintf(stderr, "stage2_verify: AST copy failed\n"); return 1; }
  /* Methods the analysis synthesizes into nt_an alone are not lowered. */
  spnl_ebpf_set_pristine(nt_ast);
  Compiler *c = comp_new(nt_an);
  analyze_program(c);
  char *out = want_ir ? cc_build_ir_text(c) : spnl_ebpf_codegen_str(c, nt_ast, argv[2]);
  fputs(out, stdout);

  /* E154: **in-process consumer 境界**。SPNL_BPF_SHADOW=1 か SPNL_BPF_BACKEND=mlir
   * のときだけ、宣言 manifest を SPNL_BPF_MANIFEST が指す先へ書く。
   *
   * stdout には触れないので **既定経路の .bpf.c は byte-identical**。
   * (stage1 の text driver 側は spbpf_manifest_emit_if_requested() が同じ条件で
   *  同じことをする。in-process ではその関数が compile out されるので、
   *  header が用意している spbpf_manifest_take_json() をここで使う。) */
  if (!want_ir) {
    const char *path    = getenv("SPNL_BPF_MANIFEST");
    const char *shadow  = getenv("SPNL_BPF_SHADOW");
    const char *backend = getenv("SPNL_BPF_BACKEND");
    int want = (shadow && !strcmp(shadow, "1")) || (backend && !strcmp(backend, "mlir"));
    if (want && path) {
      char *json = spbpf_manifest_take_json();
      if (!json) {
        /* **黙って成功にしない。** manifest を信用できないことは stderr に出す。 */
        fprintf(stderr, "spbpf: manifest is not usable (in-process)\n");
        return 1;
      }
      FILE *f = fopen(path, "w");
      if (!f) { perror("spbpf: manifest open"); free(json); return 1; }
      fputs(json, f);
      fclose(f);
      free(json);
    }
  }
  spbpf_manifest_release();   /* take しなかった場合の明示解放 */
  return 0;
}
