/* SPDX-License-Identifier: GPL-2.0
 *
 * spnl_spbpf_schema_check — 生成した P013 schema JSON を **libspbpf の公開
 * C ABI (spinel-mlir-c/SpBPF.h) で in-process に検証する** (E154 の
 * 「libspbpf C ABI を消費する」checkpoint)。
 *
 * spinel-ebpf 所有のこの binary が spinel-llvm の静的 library
 * (libSpinelMLIRCAPI.a + libSpinelMLIRSpBPFSchema.a) をリンクする。依存方向は
 * spinel-ebpf -> spinel-llvm の一方向のまま。
 *
 * C ABI が公開しているのは schema の parse / serialize だけで、**compile は
 * 公開されていない** — object 生成は引き続き外部 tool (spbpf-compile) が行う。
 * この境界を広げるのは spinel-llvm 側の ABI 拡張であり、ここでは扱わない。
 *
 * 使い方: spnl_spbpf_schema_check <schema.json>
 *   exit 0 = 正典 parser が受理 (正準 JSON を stdout へ)
 *   exit 1 = 拒否 (理由を stderr へ)
 *   exit 2 = usage / IO エラー
 *
 * Build: tools/build_spbpf_schema_check.sh
 */
#include "spinel-mlir-c/SpBPF.h"
#include "spinel-mlir-c/Support.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <schema.json>\n", argv[0]);
        return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", argv[1]);
        return 2;
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = (char *)malloc((size_t)n + 1);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) {
        fprintf(stderr, "cannot read %s\n", argv[1]);
        fclose(f);
        free(buf);
        return 2;
    }
    buf[n] = 0;
    fclose(f);

    /* 所有権は spinel-mlir-c/SpBPF.h のコメントが正典。 */
    char *error = NULL;
    SpBpfSchema *schema = sp_bpf_schema_parse_json(buf, (size_t)n, &error);
    free(buf);
    if (!schema) {
        fprintf(stderr, "SCHEMA_REJECT %s\n", error ? error : "(no message)");
        sp_bpf_string_destroy(error);
        return 1;
    }
    char *canon = sp_bpf_schema_serialize_json(schema);
    if (canon) {
        fputs(canon, stdout);
        sp_bpf_string_destroy(canon);
    }
    sp_bpf_schema_destroy(schema);
    return 0;
}
