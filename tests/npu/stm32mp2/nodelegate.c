/* tests/npu/stm32mp2/nodelegate.c -- a stand-in delegate that takes no operator.
 * The lane must stop when a model is left on the CPU; this is what shows it does. */
#include <stddef.h>
#include "tensorflow/lite/core/c/common.h"

static TfLiteStatus prepare(TfLiteContext *c, TfLiteDelegate *d) { return kTfLiteOk; }

TfLiteDelegate *tflite_plugin_create_delegate(const char *const *k, const char *const *v, size_t n,
                                              void (*report)(const char *))
{
	static TfLiteDelegate d;

	d.Prepare = prepare;
	return &d;
}

void tflite_plugin_destroy_delegate(TfLiteDelegate *d) {}
