// E055: e55_twocu を定義 (def.c — uint64_t) と違う型 (uint32_t) で宣言して呼ぶ CU。GCC はこの CU に DW_AT_declaration の subprogram を
// 仮引数の子付きで出す — 名前で探す前の照合 (E556 の前の dwarfParams) は先に link されたこの宣言を拾い u32 と読む
#include <stdint.h>

uint32_t e55_twocu(uint32_t a);

uint32_t e55_use(void)
{
	return e55_twocu(7);
}
