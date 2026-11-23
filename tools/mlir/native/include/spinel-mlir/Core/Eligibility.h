#ifndef SPINEL_MLIR_CORE_ELIGIBILITY_H
#define SPINEL_MLIR_CORE_ELIGIBILITY_H

#include "spinel-mlir/Contract/Model.h"
#include "spinel-mlir/Core/BorrowFacts.h"
#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <utility>
#include <string>
#include <vector>

namespace spinel_mlir::core {
struct Diagnostic {
  std::string verdict, method, location, reason, path, detail;
};
/// Decision 0014: one admitted extern call site.
struct ExternCall {
  std::string method;   ///< the method the call is in
  int64_t nodeId = -1;
  size_t externIndex = 0;  ///< into EntryFacts::externs
  /// Per declared argument, the value passed when it is an integer literal
  /// or a resolved constant; nothing for a buffer or a computed scalar. The
  /// application tool reads a device's instance index from these (0014 §4:
  /// each device has one owning context), so a site is reported as it is in
  /// the source, once, not once per path the loop expansion takes to it.
  std::vector<std::optional<int64_t>> constArgs;
};
/// Decision 0026 step 4: one resolved call between methods of the closure.
/// `caller` calls `callee` at the CallNode `nodeId`.
struct CallEdge {
  std::string caller, callee;
  int64_t nodeId = -1;
};
struct EligibilityReport {
  std::vector<Diagnostic> diagnostics;
  std::vector<std::string> methods;
  size_t nodes = 0;
  /// Node id to the type DERIVED from the entry facts, for the nodes where one
  /// could be derived. Empty when no facts were supplied. Published because the
  /// selector needs the same answer: two derivations would be two chances to
  /// disagree about what the closure is.
  std::map<int64_t, std::string> derivedTypes;
  /// Method name to its derived parameter types and result type, for the same
  /// reason and with the same rule: empty when no facts were supplied.
  std::map<std::string, std::pair<std::vector<std::string>, std::string>>
      derivedSignatures;
  /// Entry parameters the entry's own body READS. A count nothing reads needs
  /// no value, so the entry need not check that it has one -- which is what
  /// keeps the descriptor's domain the contract's rather than the body's.
  std::vector<std::string> readParameters;
  /// Decision 0008 task 3: which parameter of which reachable method borrows
  /// a buffer, and with what element type and mode. Published for the same
  /// reason as the types above -- the selector and the generator must lower
  /// from the answer the checker admitted, not from a second derivation.
  BorrowFactsResult borrows;
  /// Decision 0010 step 1: the literal constants the checked mode resolved,
  /// by name. Published so the loop-bound analysis reads the values admission
  /// used instead of resolving constants a second time.
  std::map<std::string, int64_t> constants;
  /// Decision 0014: the extern call sites admitted, in visiting order.
  std::vector<ExternCall> externCalls;
  /// Decision 0026 step 4: every call into the closure, resolved once here,
  /// in visiting order, one per call node. The loop-bound analysis, the effect
  /// derivation and the lowering read these instead of testing call nodes
  /// again.
  std::vector<CallEdge> callEdges;
  /// Decision 0041 stage 2: every admitted `a = Array.new(n, v)`, in source
  /// order per method. `count` is the size when it is a literal or a
  /// resolved constant.
  struct ArrayMake {
    std::string method, local;
    int64_t nodeId = -1;  ///< the Array.new call
    int64_t line = 0;
    std::optional<int64_t> count;
  };
  std::vector<ArrayMake> arrayMakes;
  /// The methods that make an array, and every method that calls one of
  /// them: these take the data stack's address.
  std::set<std::string> scratchMethods;
  /// How many elements the whole region holds: (bytes - one word) / the
  /// element's bytes. No array is longer, so it bounds every fill and size.
  int64_t scratchElements = 0;
  /// The most bytes of the region any path from the entry holds at once,
  /// when every Array.new size it can reach is a constant: each method's own
  /// arrays, plus the largest of its callees'. Absent when a size is not.
  std::optional<int64_t> scratchWorstBytes;
  bool checked() const { return !methods.empty() && diagnostics.empty(); }
};

/// What a contract declares about the entry, as facts about the SOURCE.
///
/// Decision 0007: "A declaration supplies entry facts; the checker must
/// validate every use and reachable callee against them." Each declared scalar
/// domain -- i32, u32, i64 -- is a Ruby Integer; the WIDTH is the C boundary's
/// business and the generated wrapper's parameter types enforce it. What
/// reaches the checker is therefore one fact per parameter: it is a non-null
/// integer.
///
/// This is not a synthetic caller. Nothing is added to the source and no call
/// is invented; the declaration is read as what it is, and every use and every
/// reachable callee is then validated against it.
/// One declared buffer parameter, as a fact about the source.
struct EntryBufferFact {
  std::string name;
  std::string element;   ///< u8 | i8 | u16 | i16 | i32 | u32 | i64
  bool readOnly = true;  ///< `in` is read-only; `inout` is not
  std::string countName;
  /// Decision 0014 (version 2): the count is a constant of the contract, and
  /// the buffer may be `cross`, reached from more than one context.
  std::optional<uint64_t> constCount;
  bool cross = false;
};

/// Decision 0014: one argument of a declared extern, as the checker needs it.
struct ExternArgFact {
  std::string name;
  bool isBuffer = false;
  std::string domain;    ///< i32 | u32 | i64 for a scalar; the element for a buffer
  bool readOnly = true;  ///< buffers only: `in` is read-only
};

/// A build-time requirement of an extern, decided at every call site from
/// constant operands: `<lhs> <op> <rhs>`, refused with `diagnostic`.
struct ExternStaticFact {
  std::string lhs, op, rhs, diagnostic;
};

/// One extern the entry may call: `<module>.<fn>`, as the contract declared
/// it. The checker admits a call whose receiver is a constant naming `module`
/// and whose name is `fn`, and checks its arity, domains and modes against
/// this; it never derives an effect contract from the name.
struct ExternFact {
  std::string module, fn;
  std::vector<ExternArgFact> args;
  bool returns = false;
  bool isrOk = false;
  std::vector<ExternStaticFact> statics;
};

struct EntryFacts {
  std::string entry;
  std::vector<std::string> parameters; ///< parameter names, in declaration order
  /// The buffers among those parameters. A buffer is an address the caller
  /// owns: it is not an integer, and the derivation gives it its own state so
  /// that arithmetic on one is a conflict rather than an accident.
  std::vector<EntryBufferFact> buffers;
  /// Decision 0014 (version 2): an application entry, with its context and the
  /// externs it may call. `context` is `thread` or `interrupt`; empty for a
  /// version 1 entry, which calls no extern and admits no literal.
  std::string context;
  std::vector<ExternFact> externs;
  /// Decision 0041 stage 2: the bytes of the context's data stack, from the
  /// contract's `scratch` row. Absent: no method may make an array.
  std::optional<uint64_t> scratchBytes;
  bool isApplication() const { return !context.empty(); }

  const EntryBufferFact *buffer(const std::string &n) const {
    for (const auto &b : buffers)
      if (b.name == n) return &b;
    return nullptr;
  }
  const ExternFact *externNamed(const std::string &module, const std::string &fn) const {
    for (const auto &e : externs)
      if (e.module == module && e.fn == fn) return &e;
    return nullptr;
  }
  bool isExternModule(const std::string &module) const {
    for (const auto &e : externs)
      if (e.module == module) return true;
    return false;
  }
};
/// What the checker is deciding admissibility FOR.
///
/// `UncheckedScalar` is decision 0005's core slice.  Decision 0015 admits
/// `+ - * / %`, unary `-` and parentheses in it, because that slice now lowers
/// them with `scalar::OverflowMode::Abort`: each failure is checked and ends
/// the program through the one failure hook.  `**`, the shifts, `abs` and the
/// bitwise operators stay refused with the diagnostics they had.  The name is
/// historical: "unchecked" was true of the slice's lowering before 0015.
///
/// `CheckedScalar` is decision 0007 task 2: the boundary returns a status, so
/// an operation whose failure is CHECKED AND REPORTED is admissible.  This is
/// not a relaxation of the same rule -- the two modes admit different programs
/// because they lower to different machines.  Everything whose failure has no
/// encoding in that status ABI stays refused.  (`**` was the example here
/// until decision 0042 stage 3: a power past the width is `ARITHMETIC` like
/// any other overflow, so the Bignum Ruby would give is never needed.)
enum class EligibilityMode { UncheckedScalar, CheckedScalar };

EligibilityReport checkEligibility(
    const contract::ContractModule &module, llvm::StringRef method,
    EligibilityMode mode = EligibilityMode::UncheckedScalar,
    const EntryFacts *facts = nullptr,
    unsigned integerBits = 64); // the body's width, which the diagnostics name
} // namespace spinel_mlir::core
#endif
