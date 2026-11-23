/* examples/doom/native/sp_core_stub.c — the no-entries answer for decision
 * 0008's adapter operations.
 *
 * bin/doom.rb reaches examples/doom/core/full/nativeprep.rb, whose NativeFFI
 * module declares the 0007 adapter's registry operations and the three entry
 * invokes as `ffi_func`s. A build made with examples/doom/build.sh CORE_DIR=...
 * links the generated adapter and the kernel's objects for them. A build
 * without CORE_DIR links this instead, so the program still builds and plays
 * its original path (the owner's condition (a): nothing is removed before
 * real-key acceptance on both hosts).
 *
 * The contract: spinel_adapter_registry_startup() answers 1 (ARGUMENT), at
 * which point Doom::Core::NativeSession refuses `-core` before anything else is
 * called, with a message naming the registry. Every other operation is present
 * and fails.
 *
 * THE INVOKES ARE DECLARED WITHOUT PARAMETERS ON PURPOSE. They exist so the
 * link resolves; they are never called, because the session refuses at
 * startup first. Their real signatures are 12, 222 and 221 arguments wide
 * (examples/doom/core/entries/NAME.contract), and restating them here would be a
 * second copy nothing checks.
 */

#include <stdint.h>

#define SP_CORE_NO_ENTRIES 1 /* the adapter's ARGUMENT status */

int32_t spinel_adapter_registry_startup(void) { return SP_CORE_NO_ENTRIES; }
int32_t spinel_adapter_registry_allocate(int32_t element, int64_t count) {
  (void)element; (void)count; return 0;
}
int32_t spinel_adapter_registry_store(int32_t id, int64_t index, int64_t value) {
  (void)id; (void)index; (void)value; return SP_CORE_NO_ENTRIES;
}
int64_t spinel_adapter_registry_load(int32_t id, int64_t index) {
  (void)id; (void)index; return -SP_CORE_NO_ENTRIES;
}
int32_t spinel_adapter_registry_store_i64_words(int32_t id, int64_t index, int64_t low, int64_t high) {
  (void)id; (void)index; (void)low; (void)high; return SP_CORE_NO_ENTRIES;
}
int32_t spinel_adapter_registry_load_i64_words(int32_t id, int64_t index, int32_t out_id,
                                                int64_t low_index, int64_t high_index) {
  (void)id; (void)index; (void)out_id; (void)low_index; (void)high_index; return SP_CORE_NO_ENTRIES;
}
int32_t spinel_adapter_registry_release(int32_t id) { (void)id; return SP_CORE_NO_ENTRIES; }
int32_t spinel_adapter_doom_core_input_invoke() { return SP_CORE_NO_ENTRIES; }
int32_t spinel_adapter_doom_core_step_invoke() { return SP_CORE_NO_ENTRIES; }
int32_t spinel_adapter_doom_core_render_invoke() { return SP_CORE_NO_ENTRIES; }
