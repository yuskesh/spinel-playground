/* SPDX-License-Identifier: GPL-2.0
 *
 * spnl/amp_abi.h — AMP board profile の**選択**だけを行うヘッダ (P009 T4)
 *
 * ここにあるのは「どの board の固定 ABI を読むか」の 1 択だけで、**ABI の中身は
 * 1 バイトもここに書かない**。それが要点である。
 *
 * P009 の H2 はこう言っている:
 *
 *   > ベンダ依存は (a) 固定 ABI のアドレス値と (b) Zephyr の board overlay の
 *   > 2 箇所に閉じており、runtime / codegen / A-core drain は無改変で通る。
 *   > **反証条件**: runtime か codegen に `#ifdef` が必要になった時点で H2 は崩れ、
 *   > 「可搬」ではなく「移植」になる。
 *
 * その反証条件を守るために、条件分岐を **この 1 ファイルに閉じ込め**、他は
 * `#include "spnl/amp_abi.h"` と書くだけにする。amp_m7_runtime.c / amp_check.c /
 * amp_a55_drain.c / a55_stage.c / a55_cmd.c は board を 1 つも知らない。
 *
 * 「選択の `#ifdef` も `#ifdef` ではないか」— そのとおりで、ごまかす気はない。
 * 区別しているのは**どこに置いたか**である。ここにあるのは「(a) のどの値の組を
 * 読むか」であって、**ロジックの分岐ではない**。runtime の関数の中に board 別の
 * 経路が生えたら、そのときは H2 が崩れたと記録する。
 *
 * 既定は i.MX95 M7 — 先に実証された board を既定にしておくと、board を指定しない
 * 既存のビルドが**一字一句同じ出力**になる (T4-a の退行検査はこれを測る)。
 */
#ifndef SPNL_AMP_ABI_H
#define SPNL_AMP_ABI_H

#if defined(SPNL_AMP_BOARD_STM32MP2M33)
#  include "spnl/amp_abi_stm32mp2m33.h"
#elif defined(SPNL_AMP_BOARD_IMX95M7) || !defined(SPNL_AMP_BOARD)
#  include "spnl/amp_abi_imx95m7.h"
#else
#  error "spnl/amp_abi.h: unknown AMP board profile — define SPNL_AMP_BOARD_IMX95M7 or SPNL_AMP_BOARD_STM32MP2M33"
#endif

#endif /* SPNL_AMP_ABI_H */
