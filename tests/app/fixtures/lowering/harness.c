/* tests/app/fixtures/lowering/harness.c -- decision 0014, Task 5: the ABI
 * fixtures, native. It links the six entries of body.rb with providers that
 * record every call, and prints one `ok`/`FAIL` line per expectation. The
 * generated headers name the entries; the generated extern header names the
 * providers, and a provider defined here with another signature would not
 * compile against it (bad_provider.c is that control). */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "tick.h"
#include "send_zero.h"
#include "send_n.h"
#include "untaken.h"
#include "oob_str.h"
#include "oob_dec.h"
#include "externs.h"

static int fails;
#define CHECK(name, cond) do { if (cond) printf("  ok   %s\n", name); \
  else { printf("  FAIL %s\n", name); fails++; } } while (0)

/* The providers: each records what it received. */
static int adc_calls;
static int32_t spc_board_adc_latest_value = 42;
int32_t spc_board_adc_latest(uint32_t ch) { adc_calls++; return ch == 0 ? spc_board_adc_latest_value : -1; }

static int put_calls;
static uint8_t put_data[64];
static uint32_t put_len, put_n;
int32_t spc_channel_telemetry_put(const uint8_t *data, uint32_t data_len, uint32_t n) {
  put_calls++;
  put_len = data_len;
  put_n = n;
  memcpy(put_data, data, n < sizeof put_data ? n : sizeof put_data);
  return 1;
}

static int log_calls;
static uint8_t log_data[64];
static uint32_t log_len, log_n;
void spc_log_write(const uint8_t *data, uint32_t data_len, uint32_t n) {
  log_calls++;
  log_len = data_len;
  log_n = n;
  memcpy(log_data, data, n < sizeof log_data ? n : sizeof log_data);
}

int main(void) {
  /* tick: the whole path. */
  {
    int32_t reading[1] = {0};
    uint8_t frame[16]; memset(frame, 0, sizeof frame);
    uint8_t shared[8] = {0}, priv[8] = {9, 8, 7, 6, 5, 4, 3, 2}, small[4] = {1, 2, 3, 4};
    int32_t st = spinel_core_tick(reading, frame, shared, priv, small);
    CHECK("tick returns OK", st == SPINEL_CORE_OK);
    CHECK("tick stored the extern's return through the cross buffer", reading[0] == 42);
    CHECK("tick: the provider received the state buffer's pointer and its constant count",
          put_calls == 1 && put_len == 16);
    CHECK("tick: put_str and put_dec wrote temp=42, and n counted it",
          put_n == 7 && memcmp(put_data, "temp=42", 7) == 0);
    CHECK("tick: the literal reached the provider as its bytes and its length",
          log_calls == 1 && log_len == 4 && log_n == 4 && memcmp(log_data, "tick", 4) == 0);
    CHECK("tick: the helper reached with a cross argument copied through it",
          shared[0] == 9);
    CHECK("tick: the private helper copied too", priv[1] == 2);
    CHECK("tick: the extern was called once with its constant guard folded", adc_calls == 1);
  }
  /* send_zero: a constant-invalid send fails its first guard at run time. */
  {
    uint8_t frame[16] = {0};
    put_calls = 0;
    int32_t st = spinel_core_send_zero(frame);
    CHECK("send_zero returns ARGUMENT", st == SPINEL_CORE_ARGUMENT);
    CHECK("send_zero: the provider recorded no call", put_calls == 0);
  }
  /* send_n: the same guard, from state; effects before the call remain. */
  {
    uint8_t frame[16] = {0};
    int32_t ctl[1] = {0};
    put_calls = 0;
    int32_t st = spinel_core_send_n(frame, ctl);
    CHECK("send_n with n = 0 returns ARGUMENT", st == SPINEL_CORE_ARGUMENT);
    CHECK("send_n: no call, and the store before the call remains", put_calls == 0 && frame[0] == 7);
    ctl[0] = 17;
    st = spinel_core_send_n(frame, ctl);
    CHECK("send_n with n = 17 returns BOUNDS (n <= 16)", st == SPINEL_CORE_BOUNDS && put_calls == 0);
    ctl[0] = 5;
    st = spinel_core_send_n(frame, ctl);
    CHECK("send_n with n = 5 returns OK and the provider saw n = 5", st == SPINEL_CORE_OK && put_calls == 1 && put_n == 5);
  }
  /* untaken: the constant-invalid send is on a path not taken. */
  {
    uint8_t frame[16] = {0};
    int32_t ctl[1] = {0};
    put_calls = 0;
    CHECK("untaken with the path not taken returns OK", spinel_core_untaken(frame, ctl) == SPINEL_CORE_OK && put_calls == 0);
    ctl[0] = 1;
    CHECK("untaken with the path taken returns ARGUMENT", spinel_core_untaken(frame, ctl) == SPINEL_CORE_ARGUMENT && put_calls == 0);
  }
  /* out-of-bounds writes through the helpers, with canaries on both sides. */
  {
    struct { uint8_t before[8]; uint8_t small[4]; uint8_t after[8]; } s;
    memset(s.before, 0xAA, 8); memset(s.small, 0, 4); memset(s.after, 0xBB, 8);
    int32_t st = spinel_core_oob_str(s.small);
    CHECK("oob_str returns BOUNDS", st == SPINEL_CORE_BOUNDS);
    CHECK("oob_str: the prefix that fit was written", memcmp(s.small, "abcd", 4) == 0);
    uint8_t aa[8], bb[8]; memset(aa, 0xAA, 8); memset(bb, 0xBB, 8);
    CHECK("oob_str: nothing was written outside the buffer",
          memcmp(s.before, aa, 8) == 0 && memcmp(s.after, bb, 8) == 0);
    memset(s.small, 0, 4);
    st = spinel_core_oob_dec(s.small);
    CHECK("oob_dec returns BOUNDS", st == SPINEL_CORE_BOUNDS);
    CHECK("oob_dec: nothing was written outside the buffer",
          memcmp(s.before, aa, 8) == 0 && memcmp(s.after, bb, 8) == 0);
  }
  printf("harness: %d failed\n", fails);
  return fails ? 1 : 0;
}
