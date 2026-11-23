//===- Adapter.cpp - the Full adapter generated for one contract ----------===//
#include "spinel-mlir/Core/Adapter.h"

#include "llvm/ADT/StringRef.h"
#include "llvm/Support/raw_ostream.h"

#include <cctype>
#include <algorithm>
#include <map>
#include <string>
#include <vector>

using namespace llvm;

namespace spinel_mlir::core {
namespace {

StringRef adapterElementName(ElementType e) {
  switch (e) {
  case ElementType::U8: return "u8";
  case ElementType::I32: return "i32";
  case ElementType::U32: return "u32";
  case ElementType::I64: return "i64";
  case ElementType::I8: return "i8";
  case ElementType::U16: return "u16";
  case ElementType::I16: return "i16";
  }
  return "";
}

StringRef elementCode(ElementType e) {
  switch (e) {
  case ElementType::U8: return "SPINEL_CORE_ELEM_U8";
  case ElementType::I32: return "SPINEL_CORE_ELEM_I32";
  case ElementType::U32: return "SPINEL_CORE_ELEM_U32";
  case ElementType::I64: return "SPINEL_CORE_ELEM_I64";
  case ElementType::I8: return "SPINEL_CORE_ELEM_I8";
  case ElementType::U16: return "SPINEL_CORE_ELEM_U16";
  case ElementType::I16: return "SPINEL_CORE_ELEM_I16";
  }
  return "";
}

StringRef resultCode(ScalarDomain d) {
  switch (d) {
  case ScalarDomain::I32: return "SPINEL_CORE_ELEM_I32";
  case ScalarDomain::U32: return "SPINEL_CORE_ELEM_U32";
  case ScalarDomain::I64: return "SPINEL_CORE_ELEM_I64";
  case ScalarDomain::U64: break;
  }
  return "";
}

StringRef adapterScalarDomainName(ScalarDomain d) {
  switch (d) {
  case ScalarDomain::I32: return "i32";
  case ScalarDomain::U32: return "u32";
  case ScalarDomain::I64: return "i64";
  case ScalarDomain::U64: return "u64";
  }
  return "";
}

StringRef adapterScalarCType(ScalarDomain d) {
  switch (d) {
  case ScalarDomain::I32: return "int32_t";
  case ScalarDomain::U32: return "uint32_t";
  case ScalarDomain::I64: return "int64_t";
  case ScalarDomain::U64: return "uint64_t";
  }
  return "";
}

StringRef adapterElementCType(ElementType e) {
  switch (e) {
  case ElementType::U8: return "uint8_t";
  case ElementType::I32: return "int32_t";
  case ElementType::U32: return "uint32_t";
  case ElementType::I64: return "int64_t";
  case ElementType::I8: return "int8_t";
  case ElementType::U16: return "uint16_t";
  case ElementType::I16: return "int16_t";
  }
  return "";
}

} // namespace

void emitRegistryHeader(raw_ostream &os) {
  os << R"(/* Generated -- do not edit.
 *
 * The registry every generated adapter shares. Ids are never reused while the
 * process lives, so there is ONE of these: two registries would each issue a
 * 1, and a caller that handed one adapter's id to another would name live
 * storage in the wrong place with neither able to tell.
 */
#ifndef SPINEL_ADAPTER_REGISTRY_H
#define SPINEL_ADAPTER_REGISTRY_H

#include <stdint.h>

#ifndef SPINEL_CORE_ELEM_DEFINED
#define SPINEL_CORE_ELEM_DEFINED 1
enum {
  SPINEL_CORE_ELEM_U8 = 1,
  SPINEL_CORE_ELEM_I32 = 2,
  SPINEL_CORE_ELEM_U32 = 3,
  SPINEL_CORE_ELEM_I64 = 4,
  SPINEL_CORE_ELEM_I8 = 5,
  SPINEL_CORE_ELEM_U16 = 6,
  SPINEL_CORE_ELEM_I16 = 7
};
#endif

#ifndef SPINEL_CORE_STATUS_DEFINED
#define SPINEL_CORE_STATUS_DEFINED 1
enum {
  SPINEL_CORE_OK = 0,
  SPINEL_CORE_ARGUMENT = 1,
  SPINEL_CORE_ARITHMETIC = 2,
  SPINEL_CORE_BOUNDS = 3,
  SPINEL_CORE_CAPACITY = 4
};
#endif

typedef struct {
  int32_t element;
  int64_t count;
  void *data;
  int live;
  int poisoned;
  int bound;   /* decision 0021: the caller's read-only memory, not ours */
} spinel_adapter_entry;

int32_t spinel_adapter_registry_startup(void);
int32_t spinel_adapter_registry_allocate(int32_t element, int64_t count);
int32_t spinel_adapter_registry_bind(int32_t element, int64_t count,
                                     uint64_t address);
int32_t spinel_adapter_registry_store(int32_t id, int64_t index, int64_t value);
int64_t spinel_adapter_registry_load(int32_t id, int64_t index);
int32_t spinel_adapter_registry_store_i64_words(int32_t id, int64_t index,
                                                int64_t low, int64_t high);
int32_t spinel_adapter_registry_load_i64_words(int32_t id, int64_t index,
                                               int32_t out_id,
                                               int64_t low_index,
                                               int64_t high_index);
int32_t spinel_adapter_registry_release(int32_t id);

/* For the generated invoke, which holds the lock across the whole call. */
void spinel_adapter_registry_lock(void);
void spinel_adapter_registry_unlock(void);
int spinel_adapter_registry_started(void);
spinel_adapter_entry *spinel_adapter_registry_find(int32_t id);

#endif
)";
}

void emitRegistrySource(raw_ostream &os) {
  // The table's slots are counted from SPINEL_CORE_ADAPTER_ID_START, so it
  // holds the ids issued and none below them: a test that starts near the
  // ceiling gets a table of three entries, not one of two billion that it
  // clears (57 to 60 GB resident, measured in tests/core-boundary/adapter.sh
  // on 2026-10-23). With the default start, 1, the slot of an id is
  // id - 1, as it was.
  os << R"(/* Generated -- do not edit. The registry every adapter shares. */
#include "spinel_adapter_registry.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* The id budget. The real one is the positive signed 32-bit range; a test
 * lowers it to reach exhaustion without issuing two billion ids, and exercises
 * this same code rather than a second path. */
#ifndef SPINEL_CORE_ADAPTER_ID_LIMIT
#define SPINEL_CORE_ADAPTER_ID_LIMIT 2147483647
#endif

/* The id counter is WIDER than an id. `id = next_id++` on an int32_t overflows
 * when it issues INT32_MAX, which is signed overflow and not a refusal; the
 * budget check has to happen on a value that can hold one past the end. The
 * start is a constant too, so a test can begin near the real ceiling and reach
 * it in three allocations rather than two billion. */
#ifndef SPINEL_CORE_ADAPTER_ID_START
#define SPINEL_CORE_ADAPTER_ID_START 1
#endif

static pthread_mutex_t lock;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static int init_failed;
static int broken;
static spinel_adapter_entry *entries;
static int64_t entry_count;
static int64_t next_id = SPINEL_CORE_ADAPTER_ID_START;

/* Once, whatever the threads do. Reading and writing a plain flag outside the
 * lock let two callers initialise the same mutex twice, and let one see
 * `started` before the counter it guards was set. pthread_once is the whole
 * answer: the initialisation that everything else is serialised BY cannot
 * itself be serialised by it. */
static void init_once(void) { init_failed = pthread_mutex_init(&lock, 0) != 0; }

int32_t spinel_adapter_registry_startup(void) {
  if (pthread_once(&once, init_once) != 0) return 1;
  return init_failed ? 1 : 0;
}

int spinel_adapter_registry_started(void) {
  return pthread_once(&once, init_once) == 0 && !init_failed && !broken;
}

/* A lock that did not take is not a lock. Every caller checks, and a failure
 * refuses the operation rather than proceeding unserialised. */
static int take(void) {
  if (!spinel_adapter_registry_started()) return 0;
  if (pthread_mutex_lock(&lock) != 0) return 0;
  return 1;
}

/* An unlock that failed leaves the adapter in a state nothing can reason
 * about, so it is marked and every later operation refuses. There is no
 * recovery to offer: the mutex is the only serialisation this has. */
static void drop(void) {
  if (pthread_mutex_unlock(&lock) != 0) broken = 1;
}

void spinel_adapter_registry_lock(void) { (void)take(); }
void spinel_adapter_registry_unlock(void) { drop(); }

spinel_adapter_entry *spinel_adapter_registry_find(int32_t id) {
  if (id < SPINEL_CORE_ADAPTER_ID_START ||
      (int64_t)id - SPINEL_CORE_ADAPTER_ID_START >= entry_count)
    return 0;
  spinel_adapter_entry *e = &entries[(int64_t)id - SPINEL_CORE_ADAPTER_ID_START];
  return e->live ? e : 0;
}

static size_t width_of(int32_t element) {
  switch (element) {
  case SPINEL_CORE_ELEM_U8: return 1;
  case SPINEL_CORE_ELEM_I8: return 1;
  case SPINEL_CORE_ELEM_U16: return 2;
  case SPINEL_CORE_ELEM_I16: return 2;
  case SPINEL_CORE_ELEM_I32: return 4;
  case SPINEL_CORE_ELEM_U32: return 4;
  case SPINEL_CORE_ELEM_I64: return 8;
  }
  return 0;
}

/* Exhaustion FAILS the allocation; it does not wrap. An id that came round
 * again would name storage its previous holder still believes in. The
 * comparison is on the wide counter, so the candidate one past the ceiling is
 * a value and not an overflow. Under the lock. */
static int id_budget_left(void) {
  return next_id > 0 && next_id <= (int64_t)SPINEL_CORE_ADAPTER_ID_LIMIT &&
         next_id <= 2147483647;
}

/* Records `data` under the next id, or answers 0 with nothing recorded. Under
 * the lock; the caller frees what it allocated if this answers 0. */
static int32_t issue(int32_t element, int64_t count, void *data, int bound) {
  const int64_t slot = next_id - SPINEL_CORE_ADAPTER_ID_START;
  if (slot >= entry_count) {
    const int64_t grown = slot + 64;
    spinel_adapter_entry *bigger =
        (spinel_adapter_entry *)realloc(entries, (size_t)grown * sizeof *bigger);
    if (!bigger) return 0;
    memset(bigger + entry_count, 0, (size_t)(grown - entry_count) * sizeof *bigger);
    entries = bigger;
    entry_count = grown;
  }
  entries[slot].element = element;
  entries[slot].count = count;
  entries[slot].data = data;
  entries[slot].live = 1;
  entries[slot].poisoned = 0;
  entries[slot].bound = bound;
  const int32_t id = (int32_t)next_id;
  next_id++;
  return id;
}

int32_t spinel_adapter_registry_allocate(int32_t element, int64_t count) {
  const size_t width = width_of(element);
  if (width == 0 || count < 0) return 0;
  if (!take()) return 0;
  if (!id_budget_left() || (uint64_t)count > (uint64_t)SIZE_MAX / width) {
    drop();
    return 0;
  }
  void *data = 0;
  if (count > 0) {
    data = calloc((size_t)count, width);   /* initialised, as the contract says */
    if (!data) {
      drop();
      return 0;
    }
  }
  const int32_t id = issue(element, count, data, 0);
  if (id == 0) free(data);
  drop();
  return id;
}

/* Decision 0021: READ-ONLY storage the caller placed, at `address`, of `count`
 * elements. The registry neither allocates nor frees it and never writes it:
 * store, store_i64_words and load_i64_words into it refuse, an invoke refuses
 * it anywhere but an `in` position, and release only invalidates the id. The
 * descriptor is checked as the kernel's entry checks one (buffer-boundary.md,
 * task 3): a nonzero count needs a non-NULL address aligned for the element,
 * and `count x width` and `address + size` must not overflow unsigned 64 bits
 * (nor the address space). What it CANNOT check is that the caller's memory
 * holds `count` elements; that is the caller's claim, as a raw pointer's
 * capacity is at the kernel's own boundary (decision 0007). */
int32_t spinel_adapter_registry_bind(int32_t element, int64_t count,
                                     uint64_t address) {
  const uint64_t width = (uint64_t)width_of(element);
  if (width == 0 || count < 0) return 0;
  if (count > 0) {
    if (address == 0 || address % width != 0) return 0;
    if ((uint64_t)count > UINT64_MAX / width) return 0;
    const uint64_t size = (uint64_t)count * width;
    if (size > UINT64_MAX - address) return 0;
    if ((uint64_t)(uintptr_t)address != address ||
        (uint64_t)(uintptr_t)(address + size - 1) != address + size - 1)
      return 0;
  }
  if (!take()) return 0;
  if (!id_budget_left()) {
    drop();
    return 0;
  }
  const int32_t id =
      issue(element, count, count > 0 ? (void *)(uintptr_t)address : 0, 1);
  drop();
  return id;
}

int32_t spinel_adapter_registry_release(int32_t id) {
  if (!take()) return SPINEL_CORE_ARGUMENT;
  spinel_adapter_entry *e = spinel_adapter_registry_find(id);
  if (!e) {
    drop();
    return SPINEL_CORE_ARGUMENT;
  }
  /* Bound memory is the caller's: releasing it only ends the id. */
  if (!e->bound) free(e->data);
  e->data = 0;
  e->live = 0;
  /* The slot stays, marked dead. The id is not returned to the pool: a second
   * release of it refuses rather than freeing whatever took its place. */
  drop();
  return SPINEL_CORE_OK;
}

int32_t spinel_adapter_registry_store(int32_t id, int64_t index, int64_t value) {
  if (!take()) return SPINEL_CORE_ARGUMENT;
  spinel_adapter_entry *e = spinel_adapter_registry_find(id);
  if (!e || e->poisoned || e->bound || e->element == SPINEL_CORE_ELEM_I64 ||
      index < 0 || index >= e->count) {
    drop();
    return SPINEL_CORE_ARGUMENT;
  }
  /* A value the element type cannot hold is ARGUMENT, not ARITHMETIC. It is
   * an entry scalar the CALLER supplied, and the adapter validates every
   * conversion before access; ARITHMETIC is for a value the KERNEL computed
   * and could not store. Nothing is written on the way out. */
  int32_t status = SPINEL_CORE_OK;
  switch (e->element) {
  case SPINEL_CORE_ELEM_U8:
    if (value < 0 || value > 255) status = SPINEL_CORE_ARGUMENT;
    else ((uint8_t *)e->data)[index] = (uint8_t)value;
    break;
  case SPINEL_CORE_ELEM_I8:
    if (value < -128 || value > 127) status = SPINEL_CORE_ARGUMENT;
    else ((int8_t *)e->data)[index] = (int8_t)value;
    break;
  case SPINEL_CORE_ELEM_U16:
    if (value < 0 || value > 65535) status = SPINEL_CORE_ARGUMENT;
    else ((uint16_t *)e->data)[index] = (uint16_t)value;
    break;
  case SPINEL_CORE_ELEM_I16:
    if (value < -32768 || value > 32767) status = SPINEL_CORE_ARGUMENT;
    else ((int16_t *)e->data)[index] = (int16_t)value;
    break;
  case SPINEL_CORE_ELEM_I32:
    if (value < -2147483648LL || value > 2147483647LL) status = SPINEL_CORE_ARGUMENT;
    else ((int32_t *)e->data)[index] = (int32_t)value;
    break;
  case SPINEL_CORE_ELEM_U32:
    if (value < 0 || value > 4294967295LL) status = SPINEL_CORE_ARGUMENT;
    else ((uint32_t *)e->data)[index] = (uint32_t)value;
    break;
  default:
    status = SPINEL_CORE_ARGUMENT;
    break;
  }
  drop();
  return status;
}

int64_t spinel_adapter_registry_load(int32_t id, int64_t index) {
  if (!take()) return -(int64_t)SPINEL_CORE_ARGUMENT;
  spinel_adapter_entry *e = spinel_adapter_registry_find(id);
  if (!e || e->poisoned || e->element == SPINEL_CORE_ELEM_I64 ||
      index < 0 || index >= e->count) {
    drop();
    return -(int64_t)SPINEL_CORE_ARGUMENT;
  }
  /* The value as its unsigned 32-bit pattern, which is never negative, so it
   * cannot be mistaken for the failure encoding. A signed element -- i8, i16
   * or i32 -- is sign-extended to 32 bits first, so every signed element is
   * decoded on the Full side by the one rule: subtract 4294967296 above
   * 2147483647. */
  int64_t out = 0;
  switch (e->element) {
  case SPINEL_CORE_ELEM_U8:  out = ((uint8_t *)e->data)[index]; break;
  case SPINEL_CORE_ELEM_I32: out = (int64_t)(uint32_t)((int32_t *)e->data)[index]; break;
  case SPINEL_CORE_ELEM_U32: out = ((uint32_t *)e->data)[index]; break;
  case SPINEL_CORE_ELEM_I8:  out = (int64_t)(uint32_t)(int32_t)((int8_t *)e->data)[index]; break;
  case SPINEL_CORE_ELEM_U16: out = ((uint16_t *)e->data)[index]; break;
  case SPINEL_CORE_ELEM_I16: out = (int64_t)(uint32_t)(int32_t)((int16_t *)e->data)[index]; break;
  default: break;
  }
  drop();
  return out;
}

int32_t spinel_adapter_registry_store_i64_words(int32_t id, int64_t index,
                                                int64_t low, int64_t high) {
  if (!take()) return SPINEL_CORE_ARGUMENT;
  spinel_adapter_entry *e = spinel_adapter_registry_find(id);
  /* Each word must be an unsigned 32-bit integer. A negative one or one above
   * the range is the caller's, so it is ARGUMENT and nothing is written. */
  if (!e || e->poisoned || e->bound || e->element != SPINEL_CORE_ELEM_I64 ||
      index < 0 || index >= e->count ||
      low < 0 || low > 4294967295LL || high < 0 || high > 4294967295LL) {
    drop();
    return SPINEL_CORE_ARGUMENT;
  }
  /* Combined with defined unsigned operations. Bit 31 of high is the sign bit
   * of the i64, and nothing here constructs INT64_MIN by negating. */
  const uint64_t bits = ((uint64_t)(uint32_t)high << 32) | (uint64_t)(uint32_t)low;
  int64_t value;
  memcpy(&value, &bits, sizeof value);
  ((int64_t *)e->data)[index] = value;
  drop();
  return SPINEL_CORE_OK;
}

int32_t spinel_adapter_registry_load_i64_words(int32_t id, int64_t index,
                                               int32_t out_id, int64_t low_index,
                                               int64_t high_index) {
  if (!take()) return SPINEL_CORE_ARGUMENT;
  spinel_adapter_entry *src = spinel_adapter_registry_find(id);
  spinel_adapter_entry *dst = spinel_adapter_registry_find(out_id);
  /* Everything checked before either word is written: the source, the
   * destination's type, that it is not the source, and BOTH indices --
   * including that they differ. A pair that shared one cell would leave the
   * caller reading one word twice. */
  if (!src || !dst || src->poisoned || dst->poisoned || dst->bound ||
      src->element != SPINEL_CORE_ELEM_I64 ||
      dst->element != SPINEL_CORE_ELEM_U32 || out_id == id ||
      index < 0 || index >= src->count ||
      low_index < 0 || low_index >= dst->count ||
      high_index < 0 || high_index >= dst->count ||
      low_index == high_index) {
    drop();
    return SPINEL_CORE_ARGUMENT;
  }
  const int64_t value = ((int64_t *)src->data)[index];
  uint64_t bits;
  memcpy(&bits, &value, sizeof bits);
  ((uint32_t *)dst->data)[low_index] = (uint32_t)(bits & 0xffffffffu);
  ((uint32_t *)dst->data)[high_index] = (uint32_t)(bits >> 32);
  drop();
  return SPINEL_CORE_OK;
}
)";
}

void emitAdapterHeader(const BoundaryContract &c, StringRef contractPath,
                       raw_ostream &os) {
  const std::string p = "spinel_adapter_" + c.entry;
  os << "/* Generated from " << contractPath << " -- do not edit.\n"
     << " *\n"
     << " * contract identity: " << boundaryIdentity(c) << "\n"
     << " * snapshot sha256:   " << c.rootDigest << "\n"
     << " *\n"
     << " * The Full-facing adapter for this contract.  It owns native storage\n"
     << " * and a registry of positive, monotonically issued ids; an id is not\n"
     << " * an address and is never reused while the process lives.\n"
     << " *\n"
     << " * This is NOT the CORE object.  malloc and pthread live here so that\n"
     << " * they do not live there, and the zero-undefined-symbol gate applies\n"
     << " * to that object and not to this one.\n"
     << " */\n"
     << "#ifndef SPINEL_ADAPTER_" << c.entry << "_H\n"
     << "#define SPINEL_ADAPTER_" << c.entry << "_H\n\n"
     << "#include <stdint.h>\n\n"
     << "/* The registry is SHARED by every adapter in the program: an id means\n"
     << " * one thing everywhere, which is what \"never reused\" requires. */\n"
     << "#include \"spinel_adapter_registry.h\"\n\n"
     << "/* Starts the adapter.  Returns 0 on success.  There is no unlocked\n"
     << " * fallback: if synchronisation cannot be initialised every operation\n"
     << " * below refuses, because an adapter that serialises nothing is not\n"
     << " * this adapter. */\n"
     << "int32_t " << p << "_startup(void);\n\n"
     << "/* A positive id, or zero on failure.  Storage is initialised.  A count\n"
     << " * of zero is a live id with no data: releasable, and every load or\n"
     << " * store on it refuses. */\n"
     << "int32_t " << p << "_allocate(int32_t element, int64_t count);\n\n"
     << "/* Decision 0021: a positive id for READ-ONLY storage the caller placed\n"
     << " * at `address`, or zero.  Nothing is allocated, copied or freed; only\n"
     << " * an `in` position of an invoke takes it, and every write refuses. */\n"
     << "int32_t " << p << "_bind(int32_t element, int64_t count, uint64_t address);\n\n"
     << "/* Every element but i64.  i64 storage needs the word\n"
     << " * operations, and using the wrong one is ARGUMENT rather than a\n"
     << " * reinterpretation. */\n"
     << "int32_t " << p << "_store(int32_t id, int64_t index, int64_t value);\n\n"
     << "/* One operation, not a validation followed by an unchecked read: the\n"
     << " * answer is an unsigned 32-bit value in 0..4294967295, or the NEGATIVE\n"
     << " * status on failure.  The two ranges are disjoint, so neither end of\n"
     << " * this uses INT64_MIN and no separate error channel is needed. */\n"
     << "int64_t " << p << "_load(int32_t id, int64_t index);\n\n"
     << "/* i64 storage, as two unsigned 32-bit words.  Words are numbers, so\n"
     << " * this wire contract does not depend on native byte order. */\n"
     << "int32_t " << p << "_store_i64_words(int32_t id, int64_t index,\n"
     << "                                   int64_t low, int64_t high);\n\n"
     << "/* Both output indices are validated before EITHER word is written, and\n"
     << " * the whole transfer happens under one lock.  The destination must be\n"
     << " * live u32 storage that is not the source. */\n"
     << "int32_t " << p << "_load_i64_words(int32_t id, int64_t index,\n"
     << "                                  int32_t out_id, int64_t low_index,\n"
     << "                                  int64_t high_index);\n\n"
     << "/* Invokes the kernel.  The result goes to element zero of `result_id`\n"
     << " * and only on success; on failure its previous value is unchanged and\n"
     << " * every mutable participant is poisoned -- every operation on one but\n"
     << " * `release` refuses afterwards. */\n"
     << "int32_t " << p << "_invoke(";
  {
    // Positional identifiers, and the contract's names in the comments.
    //
    // A contract name put straight into C collides three ways, all measured: a
    // buffer `src` beside a scalar `src_id` gives two parameters called
    // `src_id`; a scalar called `result_id` collides with the generated one;
    // and a name that is one of the including unit's typedefs shadows it. The
    // CORE header solved this the same way and for the same reason -- a
    // parameter name has no ABI, so nothing a caller can observe changes.
    size_t slot = 0;
    std::vector<std::string> decls, notes;
    for (const Param &o : c.order) {
      std::string d, n;
      if (o.kind == Param::Kind::Buffer) {
        const BufferParam &b = c.buffers[o.index];
        d = "int32_t sp_arg" + std::to_string(slot);
        n = b.name + " -- the id of " + adapterElementName(b.element).str() + " " +
            (b.mode == AccessMode::In ? "in" : "inout") + " storage";
      } else {
        const ScalarParam &sp = c.scalars[o.index];
        if (!sp.countsFor.empty()) continue;   // a count comes from the registry
        d = adapterScalarCType(sp.domain).str() + " sp_arg" + std::to_string(slot);
        n = sp.name + " (" + adapterScalarDomainName(sp.domain).str() + ")";
      }
      ++slot;
      decls.push_back(d);
      notes.push_back(n);
    }
    decls.push_back("int32_t sp_result_id");
    notes.push_back("the storage this call publishes its result into");
    size_t widest = 0;
    for (const auto &d : decls) widest = std::max(widest, d.size());
    const std::string indent(8 + p.size() + 8, ' ');
    for (size_t i = 0; i < decls.size(); ++i) {
      const bool last = i + 1 == decls.size();
      if (i) os << indent;
      os << decls[i] << (last ? ");" : ",")
         << std::string(widest - decls[i].size() + (last ? 1 : 2), ' ')
         << "/* " << notes[i] << " */\n";
    }
  }
  os << "\n"
     << "/* Frees live storage and invalidates its registry entry; bound storage\n"
     << " * is the caller's and is only invalidated.  A second release of the\n"
     << " * same id refuses. */\n"
     << "int32_t " << p << "_release(int32_t id);\n\n"
     << "#endif\n";
}

void emitAdapterRuby(const BoundaryContract &c, StringRef contractPath,
                     raw_ostream &os) {
  const std::string p = "spinel_adapter_" + c.entry;
  std::string mod = "CoreBoundary";
  bool upper = true;
  for (char ch : c.entry) {
    if (ch == '_') { upper = true; continue; }
    mod += upper ? static_cast<char>(::toupper(static_cast<unsigned char>(ch))) : ch;
    upper = false;
  }

  os << "# Generated from " << contractPath << " -- do not edit.\n"
     << "#\n"
     << "# contract identity: " << boundaryIdentity(c) << "\n"
     << "# snapshot sha256:   " << c.rootDigest << "\n"
     << "#\n"
     << "# The Full-facing module for this contract. Every method is a thin\n"
     << "# wrapper over one C operation: the adapter validates and acts in the\n"
     << "# same call, so nothing here checks first and reads after.\n"
     << "module " << mod << "\n"
     << "  ELEM_U8 = 1\n"
     << "  ELEM_I32 = 2\n"
     << "  ELEM_U32 = 3\n"
     << "  ELEM_I64 = 4\n"
     << "  ELEM_I8 = 5\n"
     << "  ELEM_U16 = 6\n"
     << "  ELEM_I16 = 7\n\n"
     << "  OK = 0\n"
     << "  ARGUMENT = 1\n"
     << "  ARITHMETIC = 2\n"
     << "  BOUNDS = 3\n"
     << "  CAPACITY = 4\n\n"
     << "  ffi_func :" << p << "_startup, [], :int32\n"
     << "  ffi_func :" << p << "_allocate, [:int32, :int64], :int32\n"
     << "  # The address travels as :int64 and the C side takes it as uint64_t.\n"
     << "  ffi_func :" << p << "_bind, [:int32, :int64, :int64], :int32\n"
     << "  ffi_func :" << p << "_store, [:int32, :int64, :int64], :int32\n"
     << "  # `:int64` is safe for this one BECAUSE of the encoding: the answer\n"
     << "  # is 0..4294967295 or a small negative status, so it never carries\n"
     << "  # INT64_MIN, which this pin returns as nil.\n"
     << "  ffi_func :" << p << "_load, [:int32, :int64], :int64\n"
     << "  ffi_func :" << p << "_store_i64_words, [:int32, :int64, :int64, :int64], :int32\n"
     << "  ffi_func :" << p << "_load_i64_words, [:int32, :int64, :int32, :int64, :int64], :int32\n"
     << "  ffi_func :" << p << "_invoke, [";
  {
    bool first = true;
    for (const Param &o : c.order) {
      if (o.kind == Param::Kind::Scalar && !c.scalars[o.index].countsFor.empty())
        continue;
      if (!first) os << ", ";
      first = false;
      os << (o.kind == Param::Kind::Buffer ? ":int32" : ":int64");
    }
    if (!first) os << ", ";
    os << ":int32], :int32\n";
  }
  os << "  ffi_func :" << p << "_release, [:int32], :int32\n\n"
     << "  # The ffi_func bindings are reached through the module name. A bare\n"
     << "  # call to one inside `def self.` does not resolve on this pin --\n"
     << "  # measured: `unsupported call: node ... recv=-`.\n"
     << "  def self.startup\n"
     << "    " << mod << "." << p << "_startup\n"
     << "  end\n\n"
     << "  def self.allocate_storage(element, count)\n"
     << "    " << mod << "." << p << "_allocate(element, count)\n"
     << "  end\n\n"
     << "  # Decision 0021: read-only storage the caller placed; zero on refusal.\n"
     << "  def self.bind_storage(element, count, address)\n"
     << "    " << mod << "." << p << "_bind(element, count, address)\n"
     << "  end\n\n"
     << "  def self.store(id, index, value)\n"
     << "    " << mod << "." << p << "_store(id, index, value)\n"
     << "  end\n\n"
     << "  # One call, one answer. A negative is the status; anything else is\n"
     << "  # the element's unsigned 32-bit pattern, and only a signed element --\n"
     << "  # i8, i16 or i32, sign-extended to 32 bits by the adapter -- is\n"
     << "  # decoded; an unsigned pattern already IS the value.\n"
     << "  def self.load(id, index, element)\n"
     << "    v = " << mod << "." << p << "_load(id, index)\n"
     << "    if v < 0\n"
     << "      v\n"
     << "    elsif (element == ELEM_I32 || element == ELEM_I16 || element == ELEM_I8) &&\n"
     << "          v >= 2147483648\n"
     << "      v - 4294967296\n"
     << "    else\n"
     << "      v\n"
     << "    end\n"
     << "  end\n\n"
     << "  # i64 storage travels as two unsigned 32-bit words. They are numbers,\n"
     << "  # so this does not depend on the native byte order, and INT64_MIN is\n"
     << "  # never built by negating.\n"
     << "  def self.store_i64_words(id, index, low, high)\n"
     << "    " << mod << "." << p << "_store_i64_words(id, index, low, high)\n"
     << "  end\n\n"
     << "  # The caller owns the destination and must not let another thread\n"
     << "  # mutate or release it between the two reads that follow: each\n"
     << "  # operation is serialised, a sequence of them is not a transaction.\n"
     << "  def self.load_i64_words(id, index, out_id, low_index, high_index)\n"
     << "    " << mod << "." << p << "_load_i64_words(id, index, out_id, low_index, high_index)\n"
     << "  end\n\n"
     << "  def self.invoke(";
  {
    bool first = true;
    size_t slot = 0;
    for (const Param &o : c.order) {
      if (o.kind == Param::Kind::Scalar && !c.scalars[o.index].countsFor.empty())
        continue;
      if (!first) os << ", ";
      first = false;
      os << "arg" << slot++;
    }
    if (!first) os << ", ";
    os << "result_id)\n    " << mod << "." << p << "_invoke(";
    first = true;
    for (size_t i = 0; i < slot; ++i) {
      if (!first) os << ", ";
      first = false;
      os << "arg" << i;
    }
    if (!first) os << ", ";
    os << "result_id)\n  end\n\n";
  }
  os << "  def self.release(id)\n"
     << "    " << mod << "." << p << "_release(id)\n"
     << "  end\n"
     << "end\n";
}

void emitAdapterSource(const BoundaryContract &c, StringRef contractPath,
                       StringRef headerName, raw_ostream &os, bool failureSites) {
  const std::string p = "spinel_adapter_" + c.entry;
  os << "/* Generated from " << contractPath << " -- do not edit.\n"
     << " *\n"
     << " * contract identity: " << boundaryIdentity(c) << "\n"
     << " * snapshot sha256:   " << c.rootDigest << "\n"
     << " */\n"
     << "#include \"spinel_adapter_" << c.entry << ".h\"\n"
     << "#include \"" << headerName << "\"\n\n"
     << "\n";
  if (failureSites)
    os << "/* Failure sites (spinel-core-kernel --failure-sites): the site a failed call\n"
       << " * stopped at, printed for the caller. */\n"
       << "#include <stdio.h>\n"
       << "extern int32_t spinel_core_" << c.entry << "_failure_site;\n\n";

  // Everything above is the per-contract operations; they delegate to the one
  // registry. The operations keep their per-contract names so that a generated
  // Ruby module per contract has its own entry points, but they are thin: the
  // storage, the ids and the lock are shared.
  {
    const char *ops[] = {"allocate", "store", "load", "store_i64_words",
                         "load_i64_words", "release"};
    (void)ops;
  }
  os << "int32_t " << p << "_startup(void) { return spinel_adapter_registry_startup(); }\n"
     << "int32_t " << p << "_allocate(int32_t element, int64_t count) {\n"
     << "  return spinel_adapter_registry_allocate(element, count);\n}\n"
     << "int32_t " << p << "_bind(int32_t element, int64_t count, uint64_t address) {\n"
     << "  return spinel_adapter_registry_bind(element, count, address);\n}\n"
     << "int32_t " << p << "_store(int32_t id, int64_t index, int64_t value) {\n"
     << "  return spinel_adapter_registry_store(id, index, value);\n}\n"
     << "int64_t " << p << "_load(int32_t id, int64_t index) {\n"
     << "  return spinel_adapter_registry_load(id, index);\n}\n"
     << "int32_t " << p << "_store_i64_words(int32_t id, int64_t index,\n"
     << "                                   int64_t low, int64_t high) {\n"
     << "  return spinel_adapter_registry_store_i64_words(id, index, low, high);\n}\n"
     << "int32_t " << p << "_load_i64_words(int32_t id, int64_t index, int32_t out_id,\n"
     << "                                  int64_t low_index, int64_t high_index) {\n"
     << "  return spinel_adapter_registry_load_i64_words(id, index, out_id,\n"
     << "                                               low_index, high_index);\n}\n"
     << "int32_t " << p << "_release(int32_t id) {\n"
     << "  return spinel_adapter_registry_release(id);\n}\n\n";

  // ---- invoke, which is the contract-specific part ------------------------
  std::map<std::string, std::string> slotOf;   /* contract name -> generated */
  os << "int32_t " << p << "_invoke(";
  {
    size_t slot = 0;
    bool first = true;
    for (const Param &o : c.order) {
      std::string name, decl;
      if (o.kind == Param::Kind::Buffer) {
        name = c.buffers[o.index].name;
        decl = "int32_t sp_arg" + std::to_string(slot);
      } else {
        const ScalarParam &sp = c.scalars[o.index];
        if (!sp.countsFor.empty()) continue;
        name = sp.name;
        decl = adapterScalarCType(sp.domain).str() + " sp_arg" + std::to_string(slot);
      }
      slotOf[name] = "sp_arg" + std::to_string(slot);
      ++slot;
      if (!first) os << ", ";
      first = false;
      os << decl;
    }
    if (!first) os << ", ";
    os << "int32_t sp_result_id) {\n";
  }
  os << "  if (!spinel_adapter_registry_started()) return SPINEL_CORE_ARGUMENT;\n"
     << "  /* One lock across the WHOLE invocation, taken here and released on\n"
     << "   * every path out. No callback into Full happens while it is held. */\n"
     << "  spinel_adapter_registry_lock();\n";
  for (const Param &o : c.order) {
    if (o.kind != Param::Kind::Buffer) continue;
    const BufferParam &b = c.buffers[o.index];
    os << "  spinel_adapter_entry *sp_e" << o.index << " = "
       << "spinel_adapter_registry_find(" << slotOf[b.name] << ");\n";
  }
  os << "  spinel_adapter_entry *sp_result = "
     << "spinel_adapter_registry_find(sp_result_id);\n"
     << "  /* Poisoned result storage is refused too. A buffer that was a\n"
     << "   * mutable participant of a failed call is invalid for every\n"
     << "   * operation but release, and being handed back as a RESULT is not\n"
     << "   * an exception to that. */\n"
     << "  if (!sp_result || sp_result->poisoned || sp_result->bound || sp_result->element != "
     << resultCode(*c.result) << " || sp_result->count < 1) {\n"
     << "    spinel_adapter_registry_unlock();\n"
     << "    return SPINEL_CORE_ARGUMENT;\n"
     << "  }\n";
  for (const Param &o : c.order) {
    if (o.kind != Param::Kind::Buffer) continue;
    const BufferParam &b = c.buffers[o.index];
    // Bound storage is read-only (decision 0021): only an `in` position takes it.
    os << "  if (!sp_e" << o.index << " || sp_e" << o.index << "->poisoned || "
       << (b.mode == AccessMode::In ? std::string()
                                    : "sp_e" + std::to_string(o.index) + "->bound || ")
       << "sp_e" << o.index << "->element != " << elementCode(b.element)
       << " || " << slotOf[b.name] << " == sp_result_id) {\n"
       << "    spinel_adapter_registry_unlock();\n"
       << "    /* A result that is also a participant is refused BEFORE the\n"
       << "     * call, zero-length included: the ids name one allocation, and\n"
       << "     * writing the result would write into an argument. */\n"
       << "    return SPINEL_CORE_ARGUMENT;\n"
       << "  }\n";
  }
  os << "  const int32_t status = spinel_core_" << c.entry << "(";
  {
    bool first = true;
    for (const Param &o : c.order) {
      if (!first) os << ", ";
      first = false;
      if (o.kind == Param::Kind::Buffer) {
        const BufferParam &b = c.buffers[o.index];
        os << "(" << (b.mode == AccessMode::In ? "const " : "")
           << adapterElementCType(b.element) << " *)sp_e" << o.index << "->data";
      } else {
        const ScalarParam &s = c.scalars[o.index];
        if (!s.countsFor.empty()) {
          size_t which = 0;
          for (const Param &q : c.order)
            if (q.kind == Param::Kind::Buffer &&
                c.buffers[q.index].name == s.countsFor)
              which = q.index;
          os << "(uint64_t)sp_e" << which << "->count";
        } else {
          os << slotOf[s.name];
        }
      }
    }
    os << ", (" << adapterScalarCType(*c.result) << " *)sp_result->data);\n";
  }
  os << "  if (status != SPINEL_CORE_OK) {\n";
  if (failureSites)
    os << "    fprintf(stderr, \"spinel-core: " << c.entry
       << " answered %d at failure site %d\\n\", (int)status, (int)spinel_core_" << c.entry
       << "_failure_site);\n";
  bool anyMutable = false;
  for (const Param &o : c.order) {
    if (o.kind != Param::Kind::Buffer) continue;
    const BufferParam &b = c.buffers[o.index];
    if (b.mode == AccessMode::In) continue;
    anyMutable = true;
    os << "    /* Poisoned, not repaired: a failed call may have written a\n"
       << "     * prefix, and no rollback is promised. Everything but release\n"
       << "     * refuses from here. */\n"
       << "    sp_e" << o.index << "->poisoned = 1;\n";
  }
  if (!anyMutable)
    os << "    /* No mutable participant to poison: every buffer here is `in`,\n"
       << "     * and a read-only input stays usable after a failure. */\n";
  os << "  }\n"
     << "  /* The result is not poisoned either way. On failure the kernel left\n"
     << "   * its previous value alone, so there is nothing damaged to protect\n"
     << "   * the caller from. */\n"
     << "  spinel_adapter_registry_unlock();\n"
     << "  return status;\n"
     << "}\n";
}

} // namespace spinel_mlir::core
