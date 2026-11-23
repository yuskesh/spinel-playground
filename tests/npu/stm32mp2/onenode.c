/* tests/npu/stm32mp2/onenode.c -- a stand-in delegate that takes only the first
 * operator. It gives one partition and leaves the rest to TFLite's CPU kernels,
 * the partly delegated model the lane must stop on. */
#include <stddef.h>
#include "tensorflow/lite/builtin_ops.h"
#include "tensorflow/lite/core/c/common.h"

static void *init(TfLiteContext *c, const char *b, size_t n) { return NULL; }
static void release(TfLiteContext *c, void *d) {}
static TfLiteStatus node_step(TfLiteContext *c, TfLiteNode *n) { return kTfLiteOk; }

static TfLiteStatus prepare(TfLiteContext *c, TfLiteDelegate *d)
{
	static TfLiteRegistration r;
	TfLiteIntArray *plan;
	TfLiteIntArray *one = TfLiteIntArrayCreate(1);
	TfLiteStatus s;

	r.init = init;
	r.free = release;
	r.prepare = node_step;
	r.invoke = node_step;
	r.builtin_code = kTfLiteBuiltinDelegate;
	r.custom_name = "onenode";
	if (c->GetExecutionPlan(c, &plan) != kTfLiteOk) return kTfLiteError;
	one->data[0] = plan->data[0];
	s = c->ReplaceNodeSubsetsWithDelegateKernels(c, r, one, d);
	TfLiteIntArrayFree(one);
	return s;
}

TfLiteDelegate *tflite_plugin_create_delegate(const char *const *k, const char *const *v, size_t n,
                                              void (*report)(const char *))
{
	static TfLiteDelegate d;

	d.Prepare = prepare;
	return &d;
}

void tflite_plugin_destroy_delegate(TfLiteDelegate *d) {}
