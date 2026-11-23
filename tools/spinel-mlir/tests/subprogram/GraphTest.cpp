#include "spinel/Analysis/SubprogramGraph.h"
#include <cstdlib>
#include <iostream>
using namespace spinel::subprogram;
static void check(bool value, const char *name) {
  if (!value) {
    std::cerr << "FAIL " << name << '\n';
    std::exit(1);
  }
  std::cout << "PASS " << name << '\n';
}
int main() {
  std::vector<Method> methods = {{"leaf", {}}, {"left", {0}},
                                {"right", {0}}, {"rootA", {1, 2}},
                                {"rootB", {2}}, {"userOnly", {5}}};
  auto g = analyzeGraph(methods, {3, 4});
  check(g.error.empty() && g.cycles.empty() &&
            g.callerFirst == std::vector<size_t>({1, 2, 0}),
        "all-callers-before-shared-callee");
  check(g.reachable.size() == 6 && !g.reachable[5] && !g.cyclic[5],
        "unreachable-user-def-is-not-bpf");
  auto reversed = analyzeGraph(methods, {4, 3});
  check(reversed.callerFirst == g.callerFirst,
        "root-order-does-not-change-declaration-tiebreak");
  auto duplicateEdge = analyzeGraph({{"root", {1, 1}}, {"f", {}}}, {0});
  check(duplicateEdge.callerFirst == std::vector<size_t>({1}),
        "repeated-call-is-one-graph-edge");
  auto recursion = analyzeGraph({{"root", {1}}, {"f", {1}}}, {0});
  check(recursion.cycles.size() == 1 &&
            recursion.cycles[0].cycle == std::vector<size_t>({1, 1}) &&
            recursion.cycles[0].path == std::vector<size_t>({0, 1}) &&
            recursion.cyclic[1] && recursion.callerFirst.empty(),
        "direct-cycle-source-path");
  auto mutual = analyzeGraph({{"root", {1}}, {"f", {2}}, {"g", {1}}}, {0});
  check(mutual.cycles.size() == 1 &&
            mutual.cycles[0].cycle == std::vector<size_t>({1, 2, 1}) &&
            mutual.cycles[0].path == std::vector<size_t>({0, 1, 2}),
        "mutual-cycle-source-path");
  check(!analyzeGraph({{"root", {9}}}, {0}).error.empty(),
        "invalid-edge-fails-closed");
  check(!analyzeGraph({{"same", {}}, {"same", {}}}, {0}).error.empty(),
        "duplicate-method-fails-closed");
  check(!analyzeGraph({{"root", {}}}, {9}).error.empty(),
        "invalid-root-fails-closed");
}
