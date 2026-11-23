// E056 の fixture (scripts/e56-fixtures.sh): stdin の 1 行ごとに e56_fn を 1 回呼び (uprobe — 引数を読まない)、"called <n>" を返す。
// -rdynamic で e56_fn を .dynsym に出し、--strip-all で .symtab を除いた形 (system の libc と同じ — .dynsym だけ) が attach の正の対照
#include <stdio.h>

__attribute__((noinline)) int e56_fn(int x)
{
	__asm__ volatile("" ::: "memory");
	return x + 1;
}

int main(void)
{
	char line[64];
	int n = 0;
	setvbuf(stdout, NULL, _IONBF, 0);
	printf("ready\n");
	while (fgets(line, sizeof line, stdin)) {
		if (line[0] == 'q')
			break;
		n = e56_fn(n);
		printf("called %d\n", n);
	}
	return 0;
}
