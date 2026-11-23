#pragma once
#include <string>
#include <vector>

namespace spinel::subprogram {
// The consumer resolves source/evidence identity before constructing this model.
// Indices are declaration order; roots and callees retain source order.
struct Method {
  std::string name;
  std::vector<size_t> callees;
};
struct Cycle {
  std::vector<size_t> path;
  std::vector<size_t> cycle;
};
struct Graph {
  std::vector<size_t> callerFirst;
  std::vector<bool> reachable, cyclic;
  std::vector<Cycle> cycles;
  std::string error;
};
Graph analyzeGraph(const std::vector<Method> &methods,
                   const std::vector<size_t> &roots);
} // namespace spinel::subprogram
