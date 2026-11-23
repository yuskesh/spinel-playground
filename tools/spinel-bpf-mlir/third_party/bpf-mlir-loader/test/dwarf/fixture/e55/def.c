// E055 の分けた DWARF の fixture (scripts/split-fixtures.sh): 定義 e55_target と同じ address の alias (DWARF に e55_alias の名前の subprogram は無い)、
// 戻り値を読む uretprobe の target・2 つ目の CU の宣言と違う型の定義 e55_twocu (decl.c — GCC だけが宣言の DIE を出す — bpf-mlir E556)
#include <stdint.h>

uint64_t e55_target(uint64_t a, uint64_t b)
{
	return a + b;
}

uint64_t e55_alias(uint64_t a, uint64_t b) __attribute__((alias("e55_target")));

uint64_t e55_twocu(uint64_t a)
{
	return a * 3;
}

uint32_t e55_use(void);

int main(void)
{
	return (int)(e55_target(1, 2) + e55_use());
}
