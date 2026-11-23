// tools/npu/stm32mp2/npu_tflite.cc -- runs the embedded model through TFLite and
// the VX delegate, for the IREE dispatch in the generated npu_glue.c.
//
// A static import has no error path into IREE, so every failure stops the
// process. A model the delegate does not take whole stops it too: falling back
// to TFLite's CPU kernels would look the same to the program. What runs inside
// the delegate is the driver's choice and is not checked here.
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include "tensorflow/lite/interpreter.h"
#include "tensorflow/lite/kernels/register.h"
#include "tensorflow/lite/model.h"

namespace {

typedef TfLiteDelegate *(*create_t)(const char *const *, const char *const *, size_t, void (*)(const char *));

[[noreturn]] void die(const char *what, const char *detail = "") {
    fprintf(stderr, "spinel-npu: %s%s%s\n", what, *detail ? ": " : "", detail);
    exit(1);
}

void report(const char *m) { fprintf(stderr, "spinel-npu: delegate: %s\n", m); }

std::unique_ptr<tflite::FlatBufferModel> g_model;
std::unique_ptr<tflite::Interpreter> g_interp;

void check_side(const TfLiteTensor *t, size_t n, const char *side) {
    if (t->type != kTfLiteInt8) die("the model's tensor is not int8", side);
    if (t->bytes != n) die("the model's tensor size differs from the declaration", side);
}

void init(const char *tag, const void *model, size_t size, size_t in_n, size_t out_n) {
    fprintf(stderr, "spinel-npu: build %s\n", tag);
    // The interpreter reads the model in place; the array lives as long as the process.
    g_model = tflite::FlatBufferModel::BuildFromBuffer(static_cast<const char *>(model), size);
    if (!g_model) die("TFLite cannot read the embedded model");
    tflite::ops::builtin::BuiltinOpResolver resolver;
    tflite::InterpreterBuilder(*g_model, resolver)(&g_interp);
    if (!g_interp) die("TFLite cannot build an interpreter for the model");
    if (g_interp->subgraphs_size() != 1) die("the model has more than one subgraph; this lane checks one");
    size_t before = g_interp->execution_plan().size();

    const char *lib = getenv("SPINEL_NPU_DELEGATE");
    if (!lib || !*lib) lib = "libvx_delegate.so.2";
    fprintf(stderr, "spinel-npu: delegate %s\n", lib);
    void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    if (!h) die("cannot load the delegate", dlerror());
    create_t create = reinterpret_cast<create_t>(dlsym(h, "tflite_plugin_create_delegate"));
    if (!create) die("the delegate has no tflite_plugin_create_delegate", lib);
    TfLiteDelegate *d = create(nullptr, nullptr, 0, report);
    if (!d) die("the delegate did not start", lib);
    if (g_interp->ModifyGraphWithDelegate(d) != kTfLiteOk) die("the delegate refused the model");

    int partitions = 0, cpu = 0;
    for (int n : g_interp->execution_plan()) {
        if (g_interp->node_and_registration(n)->first.delegate) partitions++;
        else cpu++;
    }
    fprintf(stderr, "spinel-npu: nodes %zu, delegated partitions %d, cpu nodes %d\n", before, partitions, cpu);
    if (cpu != 0 || partitions != 1) die("the delegate did not take the whole model; TFLite's CPU kernels are not used here");

    if (g_interp->AllocateTensors() != kTfLiteOk) die("AllocateTensors failed");
    if (g_interp->inputs().size() != 1 || g_interp->outputs().size() != 1) die("the model does not have one input and one output");
    check_side(g_interp->input_tensor(0), in_n, "input");
    check_side(g_interp->output_tensor(0), out_n, "output");
}

}  // namespace

extern "C" void sp_npu_tflite_run(const char *tag, const void *model, size_t size,
                                  const void *in, size_t in_n, void *out, size_t out_n) {
    if (!g_interp) init(tag, model, size, in_n, out_n);
    memcpy(g_interp->input_tensor(0)->data.raw, in, in_n);
    if (g_interp->Invoke() != kTfLiteOk) die("Invoke failed");
    memcpy(out, g_interp->output_tensor(0)->data.raw, out_n);
}
