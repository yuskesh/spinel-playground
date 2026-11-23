/* E009 shim: WASI has no <sys/times.h> */
#include <time.h>
struct tms { clock_t tms_utime, tms_stime, tms_cutime, tms_cstime; };
static inline clock_t times(struct tms *t){ (void)t; return (clock_t)-1; }
