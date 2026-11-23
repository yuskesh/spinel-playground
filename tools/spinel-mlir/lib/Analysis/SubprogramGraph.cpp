#include "spinel/Analysis/SubprogramGraph.h"
#include <algorithm>
#include <functional>
#include <set>
namespace spinel::subprogram {
Graph analyzeGraph(const std::vector<Method> &methods,
                   const std::vector<size_t> &roots) {
  Graph result;
  const size_t count = methods.size();
  result.reachable.resize(count, false);
  result.cyclic.resize(count, false);
  std::set<std::string> names;
  std::vector<std::vector<size_t>> edges(count);
  for (size_t i = 0; i < count; ++i) {
    if (methods[i].name.empty() || !names.insert(methods[i].name).second) {
      result.error = "empty or duplicate method";
      return result;
    }
    std::set<size_t> seen;
    for (size_t callee : methods[i].callees) {
      if (callee >= count) {
        result.error = "callee index out of bounds";
        return result;
      }
      if (seen.insert(callee).second)
        edges[i].push_back(callee);
    }
  }
  std::set<size_t> rootSet;
  for (size_t root : roots) {
    if (root >= count || !rootSet.insert(root).second) {
      result.error = "invalid or duplicate root";
      return result;
    }
  }
  std::vector<unsigned> color(count, 0);
  std::vector<size_t> stack;
  std::set<size_t> reported;
  std::function<void(size_t)> visit = [&](size_t node) {
    result.reachable[node] = true;
    color[node] = 1;
    stack.push_back(node);
    for (size_t callee : edges[node]) {
      if (!color[callee]) {
        visit(callee);
      } else if (color[callee] == 1) {
        auto first = std::find(stack.begin(), stack.end(), callee);
        std::vector<size_t> cycle(first, stack.end());
        cycle.push_back(callee);
        if (reported.insert(callee).second)
          result.cycles.push_back({stack, cycle});
        for (size_t member : cycle)
          result.cyclic[member] = true;
      }
    }
    stack.pop_back();
    color[node] = 2;
  };
  for (size_t root : roots)
    if (!color[root])
      visit(root);

  // All root bodies have already contributed their callsites. Only the
  // non-root methods enter this queue; declaration index breaks ties.
  std::vector<size_t> incoming(count, 0);
  for (size_t node = 0; node < count; ++node)
    if (result.reachable[node])
      for (size_t callee : edges[node])
        ++incoming[callee];
  for (size_t root : roots)
    for (size_t callee : edges[root])
      --incoming[callee];
  std::set<size_t> ready;
  for (size_t node = 0; node < count; ++node)
    if (result.reachable[node] && !rootSet.count(node) && !incoming[node])
      ready.insert(node);
  while (!ready.empty()) {
    size_t node = *ready.begin();
    ready.erase(ready.begin());
    result.callerFirst.push_back(node);
    for (size_t callee : edges[node])
      if (--incoming[callee] == 0 && !rootSet.count(callee))
        ready.insert(callee);
  }
  return result;
}
} // namespace spinel::subprogram
