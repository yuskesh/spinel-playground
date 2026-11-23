/* SPDX-License-Identifier: GPL-2.0
 *
 * amp_check.c — P007 S6 / P008 S4: amp-m7 配布前 bytecode checker (decoupled verification)。
 *
 * M7 は verifier を持たない。配布前に host/A55 でこの checker が amp bytecode (.bpf.o の
 * .text) を検査し、通ったものだけを AOT → M7 slot に載せる (M7 loader は magic/abi/length
 * gate = 二重防御)。強制する性質:
 *   (1) helper allowlist: call は amp helper id (1=amp_emit, 2=amp_ktime) のみ。
 *       他 id / BPF_PSEUDO_CALL (local call) は拒否。
 *   (2) bounded control flow: 後方分岐 (off < 0) を拒否 = ループ無し ⇒ 有限実行。
 *       amp v0 は loop-free なので偽陽性なし。直線コードなので **命令数の上界がそのまま
 *       静的コスト**になる (下記 (5))。
 *   (3) [P008 S4] memory-range: すべての load/store の base が **固定 ABI 領域**に閉じる。
 *       固定 ABI により E358 積み残しの range 解析が **定数レンジチェックに退化**する:
 *       ivar は `MOV/LDDW imm` で base reg に固定アドレスを載せ `LDX/STX [reg+off]` する
 *       ので、base の即値 + off が [AMP_IVARS_BASE, +AMP_IVARS_SIZE) に入るかだけ見れば良い
 *       (BPF は memory-base 即値と data 定数を op で分離するので dataflow 不要・偽陽性なし)。
 *       stack (r10 相対) は許可。base が非固定 (ctx 等の未検証ポインタ) の load/store は拒否。
 *       helper 呼出しは (1) の id allowlist が担い、AOT が id -> AMP_HELPER_SLOT(id) を固定で
 *       焼くので、{IVARS 範囲, HELPER slots} の両次元が閉じる。
 *   (4) [P010 U2] **既定 deny**: 上のどれでもない命令は「知らない形」として拒否する。
 *       ここが (3) の前提を支えている — 検査は認識した命令の意味に基づくので、認識できない
 *       命令を素通りさせると検査そのものが無意味になる。実測でその穴を 2 つ踏んだ:
 *         - atomic (BPF_ATOMIC, mode 0xc0) は mode==0x60 の分岐に一致せず素通りし、
 *           `lock *(u64 *)(0xdeadbeef) += r2` が通っていた
 *         - r10 相対のオフセットが無制限で、`*(u64 *)(r10 - 30000) = r1` が通っていた
 *           (Linux の verifier は stack を 512B に縛るが M7 には何も無く、probe の
 *            フレーム外 = RTOS スタックに書ける)
 *       いずれも「既定 allow」の帰結なので、命令ごとの穴塞ぎでなく既定を反転して直す。
 *   (5) [P010 U2] **静的コスト**: 直線コードなので命令数に基づく上界が計算できる。
 *       cost units = 命令クラス別コスト + helper の宣言コスト。--max-cost で上限を渡すと
 *       超過を配布前に拒否する (P010 D6: 希望値は probe 作者、算出値は toolchain の所有)。
 *       これは cycle 数ではなく **platform calibration 前の単位**である。
 * これで「未検証の任意 bytecode を M7 が実行してしまう / ABI 領域外へ書く」class を配布前に潰す。
 *
 * usage: amp_check [--max-cost N] [--cost-only] <prog.bpf.o>
 *        (exit 0 = ok, 1 = reject, 2 = usage/IO)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <elf.h>

#include "spnl/amp_abi.h"   /* AMP_IVARS_BASE / AMP_IVARS_SIZE (fixed ABI) */

/* amp helper id allowlist. Extend when the amp helper set grows (E357: +ktime). */
static int amp_helper_allowed(int32_t id) { return id == 1 || id == 2; }

/* The eBPF stack frame is 512 bytes and r10 points at its top, so a legal
 * r10-relative access lives in [-512, 0). Linux's verifier enforces that; the M7
 * has nothing that would, and the AOT'd code runs on the real M7 stack, so an
 * out-of-frame store lands in whatever the RTOS keeps below the probe's frame.
 * Measured before it was enforced: `*(u64 *)(r10 - 30000) = r1` was accepted. */
#define AMP_STACK_BYTES 512

/* Static cost, in pre-calibration units (P010 D6). Not cycles: the two-layer
 * model is `static cost units -> platform calibration -> conservative cycle
 * budget`, and only the first layer belongs in a host-side checker. A unit is
 * "one simple ALU/branch instruction"; memory and helpers cost more because they
 * are where the variance lives (wait states, bus contention, the helper body).
 * Deliberately pessimistic: this bound admits probes, so erring high refuses a
 * probe that would have fit, while erring low admits one that overruns. */
#define COST_ALU     1u
#define COST_BRANCH  2u
#define COST_MEM     4u
#define COST_LDDW    2u

/* Per-helper declared cost. A helper is firmware code of known shape, so its
 * cost is a property of the runtime, not of the probe calling it. amp_emit
 * writes a record and flushes a cache line; amp_ktime reads a counter. */
static unsigned amp_helper_cost(int32_t id) {
    switch (id) {
    case 1: return 60u;   /* amp_emit: record write + cache flush + index publish */
    case 2: return 12u;   /* amp_ktime: read the time source */
    default: return 0u;   /* unreachable: the allowlist rejects first */
    }
}

/* Register-immediate tracking (S4). known: 0=unknown, 1=constant, 2=stack(r10). */
struct regv { int known; uint64_t val; };

static int check_addr(const struct regv *base, int16_t off, size_t i, const char *how,
                      char *err, size_t errlen) {
    if (base->known == 2) {                         /* r10-relative = the probe's own frame */
        if (off < -AMP_STACK_BYTES || off >= 0) {
            snprintf(err, errlen,
                     "insn %zu: %s at r10%+d is outside the probe's %d-byte stack frame "
                     "[r10-%d, r10)", i, how, off, AMP_STACK_BYTES, AMP_STACK_BYTES);
            return -1;
        }
        return 0;
    }
    if (base->known == 1) {
        uint64_t addr = base->val + (uint64_t)(int64_t)off;
        if (addr >= (uint64_t)AMP_IVARS_BASE &&
            addr <  (uint64_t)AMP_IVARS_BASE + (uint64_t)AMP_IVARS_SIZE) {
            return 0;                               /* inside the ivar carveout: allow */
        }
        snprintf(err, errlen,
                 "insn %zu: %s at 0x%llx outside the fixed ABI ivar carveout "
                 "[0x%08x, 0x%08x)", i, how, (unsigned long long)addr,
                 (unsigned)AMP_IVARS_BASE, (unsigned)(AMP_IVARS_BASE + AMP_IVARS_SIZE));
        return -1;
    }
    snprintf(err, errlen,
             "insn %zu: %s via unverifiable (non-constant, non-stack) base register",
             i, how);
    return -1;
}

/* Check a BPF .text (array of 8-byte insns; LDDW is 16). Returns 0 ok, -1 reject. */
static int amp_check_text(const uint8_t *text, size_t len, unsigned *cost_out,
                          char *err, size_t errlen) {
    unsigned cost = 0;
    if (len % 8 != 0) { snprintf(err, errlen, ".text length %zu not a multiple of 8", len); return -1; }
    size_t n = len / 8;

    struct regv reg[11];
    for (int r = 0; r < 11; r++) reg[r] = (struct regv){0, 0};
    reg[10].known = 2;   /* r10 = read-only frame pointer (stack) */
    /* r1 = ctx pointer on entry: left unknown; amp handlers ignore ctx. */

    for (size_t i = 0; i < n; i++) {
        const uint8_t *insn = text + i * 8;
        uint8_t opcode = insn[0];
        uint8_t dst    = insn[1] & 0xf;
        uint8_t src    = (insn[1] >> 4) & 0xf;
        int16_t off    = (int16_t)(insn[2] | (insn[3] << 8));
        int32_t imm    = (int32_t)(insn[4] | (insn[5] << 8) | (insn[6] << 16) | ((uint32_t)insn[7] << 24));
        uint8_t cls    = opcode & 0x07;
        uint8_t mode   = opcode & 0xe0;

        if (opcode == 0x18) {   /* LDDW: 64-bit immediate load (2 insn slots) */
            uint64_t lo = (uint32_t)imm;
            uint64_t hi = (i + 1 < n)
                ? (uint32_t)(text[(i+1)*8+4] | (text[(i+1)*8+5] << 8) |
                             (text[(i+1)*8+6] << 16) | ((uint32_t)text[(i+1)*8+7] << 24)) : 0;
            if (dst < 11) reg[dst] = (struct regv){1, lo | (hi << 32)};
            cost += COST_LDDW;
            i++;
            continue;
        }
        if (opcode == 0x85) {   /* BPF_JMP | BPF_CALL */
            if (src == 1) { snprintf(err, errlen, "insn %zu: local/pseudo call not allowed (amp is 1 program = 1 function)", i); return -1; }
            if (!amp_helper_allowed(imm)) { snprintf(err, errlen, "insn %zu: call to disallowed helper id %d (allowed: 1=amp_emit, 2=amp_ktime)", i, imm); return -1; }
            cost += amp_helper_cost(imm);
            for (int r = 0; r <= 5; r++) reg[r].known = 0;   /* r0=ret, r1-r5 clobbered */
            continue;
        }
        if (opcode == 0x95) continue;   /* EXIT */

        /* Memory classes. Only BPF_MEM addressing is understood, and the range
         * check below is what makes it safe -- so an addressing mode this walk
         * cannot interpret must be refused, not skipped. BPF_ATOMIC lands here:
         * before P010 U2 it fell through to the permissive default and
         * `lock *(u64 *)(0xdeadbeef) += r2` was accepted. */
        if (cls == 0x00 || cls == 0x01 || cls == 0x02 || cls == 0x03) {
            if (mode != 0x60) {
                snprintf(err, errlen,
                         "insn %zu: memory access with addressing mode 0x%02x "
                         "(only BPF_MEM 0x60 is understood; atomics and sign-extending "
                         "or packet-relative loads are not part of the amp subset)",
                         i, mode);
                return -1;
            }
            cost += COST_MEM;
            if (cls == 0x01) {   /* LDX: dst = *(src + off) */
                if (check_addr(&reg[src], off, i, "load", err, errlen) != 0) return -1;
                if (dst < 11) reg[dst].known = 0;   /* loaded value is unknown */
            } else if (cls == 0x02 || cls == 0x03) {   /* ST (imm) / STX (reg) */
                if (check_addr(&reg[dst], off, i, "store", err, errlen) != 0) return -1;
            } else {             /* BPF_LD that is not the LDDW handled above */
                snprintf(err, errlen, "insn %zu: unsupported BPF_LD form (opcode 0x%02x)", i, opcode);
                return -1;
            }
            continue;
        }

        /* Immediate/reg moves and add feed the constant tracking. */
        if (opcode == 0xb7 || opcode == 0xb4) {           /* MOV64/32 imm */
            if (dst < 11) reg[dst] = (struct regv){1, opcode == 0xb7 ? (uint64_t)(int64_t)imm : (uint32_t)imm};
            cost += COST_ALU;
            continue;
        }
        if (opcode == 0xbf || opcode == 0xbc) {           /* MOV64/32 reg */
            if (dst < 11) reg[dst] = reg[src];
            cost += COST_ALU;
            continue;
        }
        if ((opcode == 0x07 || opcode == 0x04) && dst < 11 && reg[dst].known == 1) {  /* ADD imm on const */
            reg[dst].val += (uint64_t)(int64_t)imm;
            cost += COST_ALU;
            continue;
        }

        /* Branches: reject back-edges (loops). */
        if (cls == 0x05 || cls == 0x06) {   /* BPF_JMP / BPF_JMP32 */
            if (off < 0) { snprintf(err, errlen, "insn %zu: backward branch off=%d (unbounded loop; amp v0 is loop-free)", i, off); return -1; }
            cost += COST_BRANCH;
            continue;
        }

        /* Ordinary arithmetic: the result stops being a tracked constant. */
        if (cls == 0x04 || cls == 0x07) {   /* ALU32/ALU64 */
            if ((opcode & 0xf0) > 0xd0) {
                snprintf(err, errlen, "insn %zu: unknown ALU operation (opcode 0x%02x)", i, opcode);
                return -1;
            }
            if (dst < 11) reg[dst].known = 0;
            cost += COST_ALU;
            continue;
        }

        /* Default DENY (P010 U2). Reaching here means this walk does not know
         * what the instruction does -- and a check that skips what it cannot
         * read is not a check. Widening the amp subset means teaching this walk
         * the new form deliberately, rather than finding out later that it had
         * been accepted all along. */
        snprintf(err, errlen,
                 "insn %zu: instruction 0x%02x is outside the amp subset "
                 "(the checker refuses what it cannot interpret)", i, opcode);
        return -1;
    }
    if (cost_out) *cost_out = cost;
    return 0;
}

/* Pull the .text section out of a BPF ELF (Elf64, host-endian little). */
static int load_text(const char *path, uint8_t **out, size_t *outlen) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror("fopen"); return -1; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz <= (long)sizeof(Elf64_Ehdr)) { fclose(f); return -1; }
    uint8_t *buf = malloc((size_t)sz);
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) { fclose(f); free(buf); return -1; }
    fclose(f);

    Elf64_Ehdr *eh = (Elf64_Ehdr *)buf;
    if (memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0) { free(buf); return -1; }
    Elf64_Shdr *sh = (Elf64_Shdr *)(buf + eh->e_shoff);
    const char *shstr = (const char *)(buf + sh[eh->e_shstrndx].sh_offset);
    for (int i = 0; i < eh->e_shnum; i++) {
        if (strcmp(shstr + sh[i].sh_name, ".text") == 0) {
            *outlen = sh[i].sh_size;
            *out = malloc(sh[i].sh_size);
            memcpy(*out, buf + sh[i].sh_offset, sh[i].sh_size);
            free(buf);
            return 0;
        }
    }
    free(buf);
    return -1;   /* no .text */
}

int main(int argc, char **argv) {
    const char *path = NULL;
    long max_cost = -1;      /* -1 = no ceiling; admission is the installer's job */
    int cost_only = 0;

    for (int a = 1; a < argc; a++) {
        if (!strcmp(argv[a], "--max-cost") && a + 1 < argc) max_cost = strtol(argv[++a], NULL, 0);
        else if (!strcmp(argv[a], "--cost-only")) cost_only = 1;
        else if (argv[a][0] == '-') { fprintf(stderr, "amp_check: unknown option %s\n", argv[a]); return 2; }
        else path = argv[a];
    }
    if (!path) {
        fprintf(stderr, "usage: %s [--max-cost N] [--cost-only] <prog.bpf.o>\n", argv[0]);
        return 2;
    }

    uint8_t *text = NULL; size_t len = 0;
    if (load_text(path, &text, &len) != 0) { fprintf(stderr, "amp_check: cannot read .text from %s\n", path); return 2; }
    char err[256] = {0};
    unsigned cost = 0;
    int rc = amp_check_text(text, len, &cost, err, sizeof err);
    free(text);
    if (rc != 0) { fprintf(stderr, "amp_check: REJECT %s: %s\n", path, err); return 1; }

    /* The computed number belongs to the toolchain, not to the probe author
     * (P010 D6): the author declares what they can accept, this says what the
     * program costs, and the two are compared here rather than trusted. */
    if (cost_only) { printf("%u\n", cost); return 0; }
    if (max_cost >= 0 && (long)cost > max_cost) {
        fprintf(stderr, "amp_check: REJECT %s: static cost %u units exceeds the declared "
                        "ceiling of %ld (P010 D6: cost units, before platform calibration)\n",
                path, cost, max_cost);
        return 1;
    }
    fprintf(stderr, "amp_check: OK %s (%zu insns, %u cost units)\n", path, len / 8, cost);
    return 0;
}
