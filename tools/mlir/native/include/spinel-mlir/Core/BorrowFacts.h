//===- BorrowFacts.h - who borrows which buffer, derived ------------------===//
//
// Decision 0008 task 3.
//
// A contract declares the ENTRY's buffers. A helper has no contract, so what
// it may do with a buffer it is handed has to be DERIVED: which of its
// parameters is an address, what the elements are, and whether it may write
// them. That derived answer is this, and there is exactly one of it --
// the checker decides admissibility from it, the selector carries it, and the
// generator lowers from it. Two derivations would be two chances to disagree
// about what the closure is.
//
// THE BOUND IS NOT HERE, AND THAT IS THE POINT. A borrow says what a buffer
// holds and whether it may be written; how MANY elements there are belongs to
// the descriptor the caller passed, and travels with the call as a hidden
// count. A helper that took its bound from a name in its own body could have
// its bound moved by its own body -- measured in decision 0007, where
// `n_src = 1000` on a four-element buffer read 496 bytes past the end.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_BORROWFACTS_H
#define SPINEL_MLIR_CORE_BORROWFACTS_H

#include <cstddef>
#include <map>
#include <string>
#include <vector>

namespace spinel_mlir::core {

/// One parameter's borrow, as a lattice element.
///
/// `None` and `Conflict` are the two ends. A parameter reached by two calls
/// that pass buffers of different element types is `Conflict` and stays there:
/// the join is monotone so a round can only move a cell UP, which is what lets
/// the derivation be run to convergence and refused if it does not get there.
struct Borrow {
  enum class Kind { None, Buffer, Conflict };
  Kind kind = Kind::None;
  std::string element;   ///< u8 | i8 | u16 | i16 | i32 | u32 | i64
  bool readOnly = true;  ///< `in` is read-only; `inout` is not
  /// Decision 0014: reached from more than one context. A helper handed a
  /// cross buffer on any call is cross for that parameter, because it has to
  /// be correct for that call; and a cross buffer never reaches an extern.
  bool cross = false;
  /// The entry parameter this borrow came from, when one call supplied it, or
  /// empty when several did. Diagnostics use it; nothing derives from it.
  std::string origin;
  /// Decision 0041 stage 2: an array a method made on its context's data
  /// stack, or a parameter that any call hands one. It is freed when its
  /// maker returns, so it never reaches an extern or a fiber body.
  bool scratch = false;

  bool isBuffer() const { return kind == Kind::Buffer; }

  /// The join. Two buffers of the same element type stay one buffer, and a
  /// read-only side makes the result read-only: a helper reached with an `in`
  /// buffer on one call and an `inout` on another may only read, because it
  /// has to be correct for both.
  static Borrow join(const Borrow &a, const Borrow &b) {
    if (a.kind == Kind::None) return b;
    if (b.kind == Kind::None) return a;
    if (a.kind == Kind::Conflict || b.kind == Kind::Conflict) {
      Borrow c;
      c.kind = Kind::Conflict;
      c.element = a.element.empty() ? b.element : a.element;
      return c;
    }
    if (a.element != b.element) {
      Borrow c;
      c.kind = Kind::Conflict;
      c.element = a.element + " and " + b.element;
      return c;
    }
    Borrow out = a;
    out.readOnly = a.readOnly || b.readOnly;
    out.cross = a.cross || b.cross;
    out.scratch = a.scratch || b.scratch;
    if (out.origin != b.origin) out.origin.clear();
    return out;
  }

  bool operator==(const Borrow &o) const {
    return kind == o.kind && element == o.element && readOnly == o.readOnly &&
           cross == o.cross && origin == o.origin &&
           scratch == o.scratch;
  }
  bool operator!=(const Borrow &o) const { return !(*this == o); }
};

/// The derived answer for a whole closure.
struct BorrowFactsResult {
  /// method name -> parameter index -> borrow. A parameter with no entry is
  /// an ordinary scalar.
  std::map<std::string, std::map<size_t, Borrow>> parameters;
  /// True when the derivation reached a fixed point within its bound. A
  /// derivation that did not is refused by the caller rather than used.
  bool settled = true;

  const Borrow *borrow(const std::string &method, size_t index) const {
    auto m = parameters.find(method);
    if (m == parameters.end()) return nullptr;
    auto p = m->second.find(index);
    if (p == m->second.end() || !p->second.isBuffer()) return nullptr;
    return &p->second;
  }
  /// Whether ANY parameter of this method borrows.
  bool borrows(const std::string &method) const {
    auto m = parameters.find(method);
    if (m == parameters.end()) return false;
    for (const auto &kv : m->second)
      if (kv.second.isBuffer()) return true;
    return false;
  }
  bool empty() const { return parameters.empty(); }
};

/// Record one call's argument into a callee's slot, returning true when the
/// slot MOVED -- which is how the round loop knows it has not settled yet.
bool recordBorrow(BorrowFactsResult &facts, const std::string &callee,
                  size_t index, const Borrow &incoming);

} // namespace spinel_mlir::core
#endif
