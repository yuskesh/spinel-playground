/* SPDX-License-Identifier: Apache-2.0
 *
 * amp_sram_probe.c — P009 T4-c: 「M33 は自分の内蔵 SRAM を使えるか」に二値で答える
 *
 * この board の固定 ABI (spnl/amp_abi_stm32mp2m33.h) は、blob に焼く 2 つのアドレスを
 * M33 内蔵 SRAM に置いている。i.MX95 が ITCM/DTCM に置けたのと違い、**この board の
 * 実行元 (DDR) は使えない** — micro-bpf の JIT が bit31 の立った即値を焼けないからで、
 * 逃げ道が SRAM しかなかった。
 *
 * その前提は**まだ測っていない**。DT の `cm33-sram1`/`cm33-sram2` は「Linux は使うな」
 * としか言っておらず、RIF がそれを M33 に与えているかはセキュアワールドの中にあって
 * Linux からは読めない。だから ABI の上に何かを積む前に、ここで答えを出す。
 *
 * E384 の amp_producer.c と同じ規律で書いてある: **結果を先に共有メモリへ置く**。
 * M33 のコンソールは今は読めているが、それに頼ると「コンソールが出ない」と
 * 「SRAM が使えない」が区別できなくなる (E383 でまさにそれを踏んだ)。A35 が
 * /dev/mem で読める語に段階を刻めば、どこまで進んだかが必ず分かる:
 *
 *   status = STARTED のまま  -> 最初の SRAM アクセスで落ちた = 使えない
 *   status = 各段の値        -> そこまでは通った
 *   status = OK              -> 読み書き・パターン保持とも成立
 *
 * 落ちた場合に失うのはリセット 1 回で、得るのは「ABI の置き場所をやり直す」という
 * 確定した情報である。
 */
#include <zephyr/kernel.h>
#include <zephyr/init.h>
#include <zephyr/cache.h>
#include <zephyr/irq.h>
#include <cmsis_core.h>            /* MPU->CTRL, __DSB, __ISB */
#include <zephyr/logging/log.h>

#include "spnl/amp_abi.h"

LOG_MODULE_REGISTER(amp_sram_probe, LOG_LEVEL_INF);

/* Bring-up 用の観測窓。ABI ではない (契約に入れると撤去できなくなる) ので、
 * ABI が定める領域より後ろの spare1 内に、base から導出して置く。 */
#define PROBE_STATUS_BASE  (AMP_SPARE1_BASE + 0x40000u)
#define PROBE_MAGIC        0x50524253u   /* 'S''B''R''P' (LE) = sram bring-up probe */

enum {
	PROBE_STARTED     = 1,   /* 共有メモリには書けた (= E384 の boot marker 相当) */
	PROBE_IVARS_WROTE = 2,   /* sram1 (IVARS) に書けた */
	PROBE_IVARS_READ  = 3,   /* sram1 から読み戻せた */
	PROBE_CODE_WROTE  = 4,   /* (未使用: sram2 の書込は MPU window 内で一括) */
	PROBE_CODE_READ   = 5,   /* sram2 から読み戻せた */
	PROBE_OK          = 0x4F4B4F4Bu, /* 'KOKO' — 全段通過 */
};

static volatile uint32_t *const g_status = (volatile uint32_t *)(uintptr_t)PROBE_STATUS_BASE;

static void publish(uint32_t step, uint32_t a, uint32_t b)
{
	g_status[1] = step;
	g_status[2] = a;
	g_status[3] = b;
	g_status[0] = PROBE_MAGIC;   /* magic は最後 (半端な状態を OK と読ませない) */
	sys_cache_data_flush_range((void *)g_status, 16);
}

/* SRAM を 1 語だけ書いて読み戻す。値を返すのは「書けた」と「同じ値が residing した」
 * を区別するため — 書き込みが黙って捨てられる形の failure が RIF にはあり得る。 */
static uint32_t probe_word(uintptr_t addr, uint32_t pattern)
{
	volatile uint32_t *p = (volatile uint32_t *)addr;
	*p = pattern;
	__asm__ volatile("dsb sy" ::: "memory");
	return *p;
}

static int amp_sram_probe_init(void)
{
	publish(PROBE_STARTED, 0, 0);

	/* --- sram1: @ivar carveout (RW であることが要る) --- */
	uint32_t iv = probe_word(AMP_IVARS_BASE, 0xA5A5001Au);
	publish(PROBE_IVARS_WROTE, iv, 0);
	uint32_t iv2 = probe_word(AMP_IVARS_BASE + AMP_IVARS_SIZE - 4u, 0x5A5A001Bu);
	publish(PROBE_IVARS_READ, iv, iv2);

	/* --- sram2: helper table + blob slot (書けた上で実行可能である必要がある) ---
	 * ここは MPU 上 RX (ATTR_MPU_FLASH) なので、素の書込みはフォルトし得る。
	 * runtime が持つ write-window (MPU を一時 disable) と同じ手順を踏む。 */
	unsigned int key = irq_lock();
#if defined(CONFIG_ARM_MPU)
	uint32_t mpu_ctrl = MPU->CTRL;
	MPU->CTRL = 0U;
	__DSB();
	__ISB();
#endif
	uint32_t cw = probe_word(AMP_HELPER_BASE, 0xC0DE001Cu);
	uint32_t cw2 = probe_word(AMP_HELPER_BASE + AMP_HELPER_SIZE - 4u, 0xC0DE001Du);
#if defined(CONFIG_ARM_MPU)
	MPU->CTRL = mpu_ctrl;
	__DSB();
	__ISB();
#endif
	irq_unlock(key);
	publish(PROBE_CODE_READ, cw, cw2);

	int ok = (iv == 0xA5A5001Au) && (iv2 == 0x5A5A001Bu) &&
		 (cw == 0xC0DE001Cu) && (cw2 == 0xC0DE001Du);

	publish(ok ? PROBE_OK : PROBE_CODE_READ, iv, cw);
	LOG_INF("sram probe: ivars@0x%08x -> 0x%08x/0x%08x  code@0x%08x -> 0x%08x/0x%08x  %s",
		(unsigned)AMP_IVARS_BASE, iv, iv2,
		(unsigned)AMP_HELPER_BASE, cw, cw2, ok ? "OK" : "MISMATCH");
	return 0;
}

/* runtime (APPLICATION 90) より前に走らせる — ABI の前提を、それを使う側より先に測る。 */
SYS_INIT(amp_sram_probe_init, APPLICATION, 80);
