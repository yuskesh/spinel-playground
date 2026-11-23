/* bm040: what the startup code, the console and the driver share. */
#ifndef BM040_BM_H
#define BM040_BM_H

#include <stdint.h>

/* r4-r11, sp, lr (setjmp.S). */
typedef uint32_t bm_jmp_buf[10];
__attribute__((returns_twice)) int bm_setjmp(bm_jmp_buf env);
__attribute__((noreturn)) void bm_longjmp(bm_jmp_buf env, int val);

void bm_puts(const char *s);
void bm_put_i64(int64_t v);
void bm_main(void);

#endif
