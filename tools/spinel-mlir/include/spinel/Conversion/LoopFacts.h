#pragma once
#include "spinel/Conversion/Consumer.h"
namespace spinel::consumer::loops {
// Provenance is checked before range transfer or IR construction.
struct Syntax {
  Operation *call = nullptr, *block = nullptr, *body = nullptr;
  Operation *count = nullptr, *parameter = nullptr, *analyzedParameter = nullptr;
  bool inclusive = false;
  std::string sourceName, analyzedName;
  std::map<std::string,std::string> localNames;
};
bool isIterator(Consumer &, Operation *);
FailureOr<Syntax> inspect(Consumer &, Operation *, unsigned depth,
                         std::function<LogicalResult(const Syntax &)> precheck = {});
// Only a structurally established lexical binding permits a name difference.
LogicalResult knownBoundLocal(Consumer &, Operation *, const Syntax &);
LogicalResult knownBoundRead(Consumer &, Operation *, const Syntax &);
} // namespace spinel::consumer::loops
