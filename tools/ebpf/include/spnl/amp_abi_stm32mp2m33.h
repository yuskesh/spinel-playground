/* SPDX-License-Identifier: GPL-2.0
 *
 * spnl/amp_abi_stm32mp2m33.h — 固定 AMP ABI (board プロファイル: STM32MP257F-DK Cortex-M33)
 *
 * P009 T4。i.MX95 M7 版 (spnl/amp_abi_imx95m7.h) の**姉妹**であり、構造・マクロ名・
 * 意味はすべて同じ。**違うのは値だけ** — それが P009 H2 の主張そのもの:
 *
 *   > ベンダ依存は (a) 固定 ABI のアドレス値と (b) Zephyr の board overlay の 2 箇所に
 *   > 閉じており、runtime / codegen / A-core drain は無改変で通る。
 *
 * このファイルに新しい種類の定数が要る、あるいは runtime に `#ifdef` が要る、と
 * なった時点で H2 は崩れる。そのときは隠さず反証として記録する (P009 の原則)。
 *
 * ---------------------------------------------------------------------------
 * この board で値が変わる理由 (実測、2026-07-29)
 * ---------------------------------------------------------------------------
 *
 * **M33 は DDR から実行する**。Zephyr の board dts は
 *   zephyr,flash = &ddr_code  (memory0@80100000)
 *   zephyr,sram  = &ddr_sys   (memory1@80a00000)
 * で、**どちらも bit31 = 1**。i.MX95 の ITCM (0x000…) / DTCM (0x200…) が偶然
 * 満たしていた JIT 制約 (下記) を、この SoC の実行元は満たさない。
 *
 * !!! JIT 制約 (i.MX95 版と共通、E351/E352/E361 実測) !!!
 *   micro-bpf host JIT の即値ロードは **負の i32 (bit31 が立つ値) を 8bit 超で拒否**
 *   する。ゆえに **blob に焼かれるアドレス** (AMP_HELPER_BASE / AMP_IVARS_BASE) は
 *   bit31 = 0 でなければならない。**焼かれないアドレス** (ring / staging / cmd /
 *   progress / capability、および blob slot 自体) にはこの制約はかからない。
 *
 * 逃げ道は M33 の**内蔵 SRAM** で、そこは bit31 = 0 (実機 device-tree より):
 *
 *   cm33-sram1   0x0A041000  124 KB
 *   cm33-sram2   0x0A060000  128 KB
 *   cm33-retram  0x0A080000  124 KB
 *
 * `0x0A0…` は Cortex-M の **Code 領域** (0x00000000–0x1FFFFFFF) に入るので、既定
 * マップで実行可能 — helper テーブル (`ldr.w pc,[pc]` を置く) と blob slot の要件を
 * 満たす。i.MX95 が ITCM(code)/DTCM(data) に分けたのと同じ形を sram2(code)/sram1(data)
 * で再現する。
 *
 * ---------------------------------------------------------------------------
 * ABI version を i.MX95 と別値にした理由
 * ---------------------------------------------------------------------------
 *
 * version gate の目的は「**この blob は、この ABI を守る firmware でだけ動く**」の検査。
 * MP2 用にアドレスを焼いた blob は i.MX95 firmware では正しく動かない ⇒ **別の ABI**。
 * よって別値を与え、既存の loud 拒否 (loader / manifest gate) が**クロスボード誤搭載を
 * そのまま弾く**ようにした。構造体は 1 バイトも変えていない。
 *
 * 数値は新旧の序列ではなく **(構造, アドレス地図) の対**の識別子である。
 */
#ifndef SPNL_AMP_ABI_STM32MP2M33_H
#define SPNL_AMP_ABI_STM32MP2M33_H

#include <stdint.h>

#define AMP_ABI_VERSION 2u   /* imx95m7 = 1。序列でなく board profile の識別子 (上記) */

/* ======================================================================== *
 *  blob-facing ABI  (blob に焼かれる。bit31 = 0 必須。変更は ABI version bump) *
 * ======================================================================== */

/* --- M33 内蔵 SRAM 地図 (実機 device-tree の cm33-* 予約と一致) --- */
#define AMP_SRAM1_BASE  0x0A041000u   /* data 側 (IVARS をここの最上位に) */
#define AMP_SRAM1_SIZE  0x0001F000u   /* 124 KiB, ends at 0x0A060000 */
#define AMP_SRAM2_BASE  0x0A060000u   /* code 側 (helper table + blob slot) */
#define AMP_SRAM2_SIZE  0x00020000u   /* 128 KiB, ends at 0x0A080000 */

/* --- helper 入口テーブル (i.MX95 版と同一機構、同一マクロ) ---
 * firmware が AMP_HELPER_BASE に 8B/slot のテーブルを置き、起動時に literal を
 * データ書込みでパッチする。codegen は `call <id>` を AMP_HELPER_SLOT(id) の即値
 * 呼出しに焼く。詳細は i.MX95 版のコメント参照 (機構は共通)。
 *
 * 配置: **sram2 の最上位 256B**。Code 領域 = 実行可、bit31=0 = JIT で焼ける。
 * Zephyr は DDR しか使わないので sram2 は空いているが、CONFIG_MPU_GAP_FILLING=y の
 * 下では **DT に書かれていない領域は能動的にアクセス不可にされる** ⇒ board overlay
 * で領域宣言が要る (H2 の (b) に当たる。examples/amp_m33_firmware の board overlay)。
 */
#define AMP_HELPER_SLOT_BYTES 8u
#define AMP_HELPER_SLOTS      32u
#define AMP_HELPER_SIZE       (AMP_HELPER_SLOT_BYTES * AMP_HELPER_SLOTS)  /* 256 B */
#define AMP_HELPER_BASE       0x0A07FF00u  /* = sram2 top - 256B */

#define AMP_HELPER_SLOT(id)   (AMP_HELPER_BASE + ((unsigned)(id) - 1u) * AMP_HELPER_SLOT_BYTES)
/* `ldr.w pc, [pc]` (T2 LDR-literal, Rt=PC, imm12=0) — ARMv7-M と ARMv8-M Mainline で
 * 同一符号化 (E381 で m7/m33 の再アセンブルが byte 一致であることを実測済)。 */
#define AMP_HELPER_LDR_PC_PC  0xF000F8DFu
#define AMP_HELPER_LITERAL(addr) (((unsigned)(addr)) | 1u)

#define AMP_HELPER_ID_EMIT    1u   /* spnl_emit -> ring publish */
#define AMP_HELPER_ID_KTIME   2u   /* ktime_ns  -> uptime ns (PHC は T5) */

/* --- ivar 置場 (@ivar の直 RMW。address は bytecode 即値) ---
 * 配置: **sram1 の最上位 256B**。bit31=0、RW。
 *
 * i.MX95 版が抱えていた「A-core から DTCM を読めるか」の未決 (AMP_IVARS_A55_ALIAS)
 * は、この board では **問題として発生しない** — sram1 は SoC のフラットな
 * アドレス空間にあり、A35 からも同じ番地で見える (ただし RIF が M33 ドメインに
 * 割り当てている場合、A35 からの読取は不正アクセス扱いでリセットを招く。
 * stm32mp257f-dk の L003 実測)。よって **A35 が ivar を直読する経路は
 * 採らない** — 値はリング経由で M33 自身に報告させる。
 */
#define AMP_IVARS_SIZE  0x00000100u    /* 256 B */
#define AMP_IVARS_BASE  0x0A05FF00u    /* = sram1 top - 256B */

/* ======================================================================== *
 *  A-core-facing ABI  (firmware<->A35 の契約。blob には無関係 = bit31 自由)    *
 * ======================================================================== */

/* すべて `spare1@81300000` (12.75 MB, no-map) の中。ベンダ DT に元からある空き予約で、
 * i.MX95 で必要だった DT/SM への追加が要らなかった (P009 T0)。
 * **オフセットは i.MX95 版と同一**にしてある (ring / +0x20000 staging / +0x30000 cmd /
 * +0x31000 progress / +0x32000 capability) — 地図が読み比べられる方が間違いに気づく。 */
#define AMP_SPARE1_BASE    0x81300000u
#define AMP_SPARE1_SIZE    0x00CC0000u

#define AMP_RING_BASE      0x81300000u    /* = spare1 base (E382/E384 で実測済の番地) */

#define AMP_STAGING_BASE   0x81320000u
#define AMP_STAGING_SIZE   0x1000u
#define AMP_STAGING_MAGIC  0x42504D41u    /* 'A''M''P''B' (LE) */
#define AMP_BLOB_MAX       512u

struct amp_blob_staging {
	uint32_t magic;
	uint32_t abi_version;
	uint32_t length;
	uint32_t ivars_size;
	/* uint8_t blob[length] がここから続く */
};

#define AMP_CMD_RING_BASE  0x81330000u
#define AMP_CMD_RING_SIZE  0x1000u

#define AMP_PROGRESS_BASE  0x81331000u
enum amp_step {
	AMP_STEP_TICK        = 10,
	AMP_STEP_POLL        = 20,
	AMP_STEP_CMD_MAGIC   = 25,
	AMP_STEP_CMD_FOUND   = 30,
	AMP_STEP_PRE_INSTALL = 40,
	AMP_STEP_PRE_WINDOW  = 45,
	AMP_STEP_IN_WINDOW   = 50,
	AMP_STEP_POST_IVARS  = 55,
	AMP_STEP_POST_MEMCPY = 60,
	AMP_STEP_POST_ICACHE = 65,
	AMP_STEP_POST_WINDOW = 70,
	AMP_STEP_POST_FLIP   = 80,
	AMP_STEP_RUN         = 90,
	AMP_STEP_RUN_DONE    = 95,
	AMP_STEP_TICK_DONE   = 100,
};

#define AMP_CAPABILITY_BASE 0x81332000u
#define AMP_CAPABILITY_SIZE 0x1000u

#define AMP_CMD_RING_MAGIC 0x444D4341u     /* 'A''C''M''D' (LE) */
#define AMP_CMD_RING_CAP   2u

enum amp_cmd_type {
	AMP_CMD_NONE = 0,
	AMP_CMD_INSTALL = 1,
	AMP_CMD_TEARDOWN = 2,
};

struct amp_cmd_rec {
	uint32_t type;
	uint32_t abi_version;
	uint32_t length;
	uint32_t ivars_size;
	uint8_t  blob[AMP_BLOB_MAX];
};

struct amp_cmd_ring {
	uint32_t magic;
	uint32_t version;
	uint32_t capacity;
	uint32_t rec_size;
	volatile uint32_t prod;
	volatile uint32_t cons;
	uint32_t _pad[2];
};

static inline struct amp_cmd_rec *amp_cmd_ring_recs(struct amp_cmd_ring *r) {
	return (struct amp_cmd_rec *)((char *)r + sizeof(struct amp_cmd_ring));
}

static inline void amp_cmd_ring_init(struct amp_cmd_ring *r) {
	r->version = 1;
	r->capacity = AMP_CMD_RING_CAP;
	r->rec_size = (uint32_t)sizeof(struct amp_cmd_rec);
	r->prod = 0;
	r->cons = 0;
	r->_pad[0] = r->_pad[1] = 0;
	r->magic = AMP_CMD_RING_MAGIC;   /* publish last */
}

static inline int amp_cmd_ring_push(struct amp_cmd_ring *r, const struct amp_cmd_rec *rec) {
	if (r->magic != AMP_CMD_RING_MAGIC) return 0;
	uint32_t prod = r->prod, cons = r->cons;
	if (prod - cons >= r->capacity) return 0;   /* full */
	amp_cmd_ring_recs(r)[prod % r->capacity] = *rec;
	r->prod = prod + 1;                          /* publish */
	return 1;
}

#endif /* SPNL_AMP_ABI_STM32MP2M33_H */
