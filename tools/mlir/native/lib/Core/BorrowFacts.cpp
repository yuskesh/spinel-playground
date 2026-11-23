//===- BorrowFacts.cpp ----------------------------------------------------===//
//
// Decision 0008 task 3. See BorrowFacts.h.
//
//===----------------------------------------------------------------------===//
#include "spinel-mlir/Core/BorrowFacts.h"

namespace spinel_mlir::core {

bool recordBorrow(BorrowFactsResult &facts, const std::string &callee,
                  size_t index, const Borrow &incoming) {
  if (incoming.kind == Borrow::Kind::None) return false;
  Borrow &slot = facts.parameters[callee][index];
  const Borrow next = Borrow::join(slot, incoming);
  if (next == slot) return false;
  slot = next;
  return true;
}

} // namespace spinel_mlir::core
