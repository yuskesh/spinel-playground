/* The unmeasured-object control of Task 10: a unit linked into the image
 * (--mutate-source) that connects no interrupt and defines one plain
 * function. It was never compiled at step 5, so it has no .su and no
 * evidence; step 10 refuses the link because an object it holds was not
 * measured (0014 §8 step 10: the objects linked are the ones measured). */
#include <stdint.h>
uint32_t spc_plain_unit(uint32_t x)
{
	return x + 1u;
}
