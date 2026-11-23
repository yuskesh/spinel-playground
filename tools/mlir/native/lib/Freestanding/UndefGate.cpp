// Undefined-symbol policy, ported verbatim from frozen classify. Preserve nine-rule order: unwind
// must precede platform externs, or declaring __aeabi_unwind_cpp_pr0 could conceal a missing
// nounwind defect.
#include "spinel-mlir/Freestanding/UndefGate.h"

#include "llvm/ADT/StringExtras.h"
#include "llvm/ADT/StringSet.h"
#include "llvm/Object/ObjectFile.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Regex.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <set>
#include <vector>

using namespace llvm;

namespace spinel_mlir::freestanding {

namespace {

// Vocabulary matching frozen module variables. static_assert fixes cardinality: silent expansion
// changes refusals into acceptance. Change counts and review cp4/identity.tsv Python pins in the
// same commit.

// Exceptions/unwinding: always DENY regardless of profile.
const StringRef kUnwind[] = {
    "__aeabi_unwind_cpp_pr0", "__aeabi_unwind_cpp_pr1", "__aeabi_unwind_cpp_pr2",
    "_Unwind_Resume", "_Unwind_RaiseException", "__gxx_personality_v0",
    "__cxa_begin_catch", "__cxa_end_catch", "__cxa_throw"};
static_assert(sizeof(kUnwind) / sizeof(StringRef) == 9, "");

// wasm-ld synthetic symbols: ALLOW only if triple starts with wasm.
const StringRef kWasmLinker[] = {
    "__stack_pointer", "__stack_low", "__stack_high", "__memory_base",
    "__table_base", "__indirect_function_table", "__linear_memory",
    "__heap_base", "__heap_end", "__global_base", "__data_end",
    "__wasm_call_ctors"};
static_assert(sizeof(kWasmLinker) / sizeof(StringRef) == 12, "");

// Frozen SEEDS_ALLOC/SEEDS_PAUSE plus constructors make reasons specific but do not change
// verdicts: they would otherwise be unknown/DENY. tools/realtime/alloc_vocabulary.tsv is canonical;
// its configure-generated header is shared with native rtcheck, preventing independent updates. The
// historical set stays thirty-one words: nineteen allocation, eight pause and four constructors,
// guarded by static_assert.
#include "spinel-mlir/Realtime/AllocVocabulary.inc"

const std::vector<StringRef> &allocatorVocabulary() {
  static const std::vector<StringRef> v = [] {
    std::vector<StringRef> out;
    for (StringRef s : kVocabAlloc) out.push_back(s);
    for (StringRef s : kVocabPause) out.push_back(s);
    for (StringRef s : kVocabConstructor) out.push_back(s);
    return out;
  }();
  return v;
}
static_assert(sizeof(kVocabAlloc) / sizeof(StringRef) == 19, "");
static_assert(sizeof(kVocabPause) / sizeof(StringRef) == 8, "");
static_assert(sizeof(kVocabConstructor) / sizeof(StringRef) == 4, "");

// Hosted Spinel runtime symbols: always DENY for freestanding.
const StringRef kHostRuntime[] = {"sp_raise_cls", "sp_raise_nil_int_op",
                                  "sp_raise",     "longjmp",
                                  "setjmp",       "_setjmp",
                                  "abort",        "exit",
                                  "__stack_chk_fail"};
static_assert(sizeof(kHostRuntime) / sizeof(StringRef) == 9, "");

// LLVM-generated mem* symbols: DENY under libc:none.
const StringRef kLibcMem[] = {
    "memcpy", "memset", "memmove", "memcmp", "__aeabi_memcpy",
    "__aeabi_memcpy4", "__aeabi_memcpy8", "__aeabi_memmove",
    "__aeabi_memmove4", "__aeabi_memmove8", "__aeabi_memset",
    "__aeabi_memset4", "__aeabi_memset8", "__aeabi_memclr",
    "__aeabi_memclr4", "__aeabi_memclr8"};
static_assert(sizeof(kLibcMem) / sizeof(StringRef) == 16, "");

// Preserve both anchored frozen regexes. Removing ^/$ changes whole-name matching to substring
// matching and changes the closed set; retain anchors for llvm::Regex too.
const char kCompilerRtRe[] =
    "^(__aeabi_[a-z0-9_]+"
    "|__(u?div|u?mod)[sdt]i3"
    "|__udivmoddi4|__divmoddi4|__udivsi3|__umodsi3|__divsi3|__modsi3"
    "|__(ashl|ashr|lshr)[sdt]i3"
    "|__(add|sub|mul|div)[sdt]f3"
    "|__(fix|float)(uns)?[a-z]+[a-z]+i?"
    "|__(eq|ne|lt|le|gt|ge|unord)[sdt]f2"
    "|__(clz|ctz|popcount|ffs|parity)[sdt]i2"
    "|__extend[sdt]f[sdt]f2|__trunc[sdt]f[sdt]f2"
    "|__mulo?[dst]i4|__mul[dt]i3"
    "|__riscv_[a-z0-9_]+)$";
const char kLibmRe[] =
    "^(sqrt|sin|cos|tan|asin|acos|atan|atan2|exp|log|log2|log10"
    "|pow|fabs|floor|ceil|round|trunc|fmod|hypot|cbrt)f?$";

bool inSet(ArrayRef<StringRef> set, StringRef s) { return llvm::is_contained(set, s); }

// Nine-rule sequence; do not reorder (see frozen classify comment).
void classify(StringRef sym, const UndefPolicy &p, Regex &compilerRt,
              Regex &libm, std::string &verdict, std::string &reason) {
  auto deny = [&](const Twine &why) { verdict = "DENY"; reason = why.str(); };
  auto allow = [&](const Twine &why) { verdict = "ALLOW"; reason = why.str(); };

  if (inSet(kUnwind, sym))
    return deny("unwind/EH: the generator did not mark every function nounwind, "
                "so the backend emitted an exception table (freestanding "
                "refuses this whatever the profile says)");
  if (llvm::is_contained(p.allowed, sym))
    return allow("platform extern declared by the profile");
  if (StringRef(p.triple).starts_with("wasm") && inSet(kWasmLinker, sym))
    return allow("linker-synthesised wasm symbol (wasm-ld defines it; it is "
                 "part of the target ABI, not a capability)");
  if (inSet(allocatorVocabulary(), sym))
    return deny("allocation/GC: the freestanding subset is the allocation-free "
                "subset (P003 decision record D-3) and this object reached an "
                "allocator");
  if (inSet(kHostRuntime, sym))
    return deny("host runtime: this is a symbol of the hosted Spinel runtime "
                "(exceptions / process exit); there is no such runtime on a "
                "freestanding target");
  if (inSet(kLibcMem, sym)) {
    if (p.libc == "none")
      return deny("libc=none but the object needs a mem* helper (ship a minimal "
                  "implementation, or remove the aggregate copy that produced it)");
    return allow("libc=" + p.libc);
  }
  if (compilerRt.match(sym)) {
    if (p.compilerRt == "allow")
      return allow("compiler-rt builtin");
    return deny("compiler_rt=deny but the object needs a builtin");
  }
  if (libm.match(sym)) {
    if (p.libm == "none")
      return deny("libm=none but the object needs " + sym +
                  " (P003 Phase 6 turns Math.* into intrinsics; until then this "
                  "is out of the subset)");
    return allow("libm=" + p.libm);
  }
  deny("not covered by any allowance in the profile (unknown symbol)");
}

} // namespace

UndefPolicy undefPolicyOf(const FreestandingProfile &profile) {
  UndefPolicy p;
  p.triple = profile.triple().str();
  p.libc = profile.libc().str();
  p.libm = profile.libm().str();
  p.compilerRt = profile.compilerRt().str();
  for (const std::string &s : profile.allowedSymbols()) p.allowed.push_back(s);
  return p;
}

bool runUndefGate(StringRef objPath, const FreestandingProfile &profile,
                  std::vector<UndefRow> &rows, std::string *infraError) {
  return runUndefGate(objPath, undefPolicyOf(profile), rows, infraError);
}

bool runUndefGate(StringRef objPath, const UndefPolicy &profile,
                  std::vector<UndefRow> &rows, std::string *infraError) {
  ErrorOr<std::unique_ptr<MemoryBuffer>> buf = MemoryBuffer::getFile(objPath);
  if (!buf) {
    *infraError =
        ("cannot read " + objPath + ": " + buf.getError().message()).str();
    return false;
  }
  Expected<std::unique_ptr<object::ObjectFile>> obj =
      object::ObjectFile::createObjectFile((*buf)->getMemBufferRef());
  if (!obj) {
    *infraError = ("cannot read " + objPath + " as an object file: " +
                   toString(obj.takeError()))
                      .str();
    return false;
  }

  // Deduplicate and sort as frozen undefined() does. Input traversal order must not make one object
  // produce different TSV bytes.
  std::set<std::string> undefined;
  for (const object::SymbolRef &s : (*obj)->symbols()) {
    Expected<uint32_t> flags = s.getFlags();
    if (!flags) {
      consumeError(flags.takeError());
      continue;
    }
    if (!(*flags & object::SymbolRef::SF_Undefined))
      continue;
    Expected<StringRef> name = s.getName();
    if (!name) {
      consumeError(name.takeError());
      continue;
    }
    if (!name->empty())
      undefined.insert(name->str());
  }

  const std::string base = sys::path::filename(objPath).str();
  Regex compilerRt(kCompilerRtRe);
  Regex libm(kLibmRe);
  bool ok = true;
  for (const std::string &sym : undefined) {
    UndefRow row;
    row.object = base;
    row.symbol = sym;
    classify(sym, profile, compilerRt, libm, row.verdict, row.reason);
    if (row.verdict == "DENY")
      ok = false;
    rows.push_back(std::move(row));
  }
  return ok;
}

std::string formatUndefTsv(ArrayRef<UndefRow> rows) {
  std::string out = "verdict\tobject\tsymbol\treason\n";
  for (const UndefRow &r : rows)
    out += r.verdict + "\t" + r.object + "\t" + r.symbol + "\t" + r.reason + "\n";
  return out;
}

} // namespace spinel_mlir::freestanding
