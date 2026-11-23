#include "spinel/Analysis/SubprogramFlow.h"
#include <functional>
namespace spinel::subprogram {
FlowResult resolveFlows(const std::vector<FunctionFlows> &functions,
                        const std::vector<size_t> &callerFirst,
                        const std::vector<size_t> &roots,
                        const std::set<Object> &exempt) {
  FlowResult result;
  result.summaries.resize(functions.size());
  std::map<int64_t, const CallSite *> sites;
  for (const auto &function : functions)
    for (const auto &site : function.sites) {
      if (site.callee >= functions.size() || !sites.emplace(site.id, &site).second) {
        result.error = "invalid callee or duplicate call token";
        return result;
      }
      if (site.arguments.size() != functions[site.callee].parameterCount) {
        result.error = "call flow arity differs from callee";
        return result;
      }
    }
  std::vector<bool> finished(functions.size(), false);
  struct Expanded {
    std::set<Object> objects, viaReturn;
    std::set<size_t> parameters;
  };
  std::function<Expanded(const FlowSource &, unsigned)> expand =
      [&](const FlowSource &source, unsigned depth) -> Expanded {
    Expanded value{source.objects, {}, source.parameters};
    if (depth > 16 && !source.returns.empty()) {
      result.error = "call provenance expansion exceeds supported depth";
      return value;
    }
    for (int64_t id : source.returns) {
      auto found = sites.find(id);
      if (found == sites.end()) {
        result.error = "unknown call return token";
        return value;
      }
      const auto &site = *found->second;
      if (!finished[site.callee]) {
        result.error = "callee summary not finalized";
        return value;
      }
      const auto &summary = result.summaries[site.callee];
      value.objects.insert(summary.returnObjects.begin(), summary.returnObjects.end());
      value.viaReturn.insert(summary.returnObjects.begin(), summary.returnObjects.end());
      for (size_t parameter : summary.returnParameters) {
        if (parameter >= site.arguments.size()) {
          result.error = "unknown returned parameter token";
          return value;
        }
        auto relay = expand(site.arguments[parameter], depth + 1);
        value.objects.insert(relay.objects.begin(), relay.objects.end());
        value.viaReturn.insert(relay.objects.begin(), relay.objects.end());
        value.viaReturn.insert(relay.viaReturn.begin(), relay.viaReturn.end());
        value.parameters.insert(relay.parameters.begin(), relay.parameters.end());
      }
    }
    return value;
  };
  auto exempted = [&](const Object &object) {
    return object.domain == Object::Domain::Map && exempt.count(object);
  };
  auto process = [&](size_t index, bool root) {
    if (index >= functions.size() || finished[index]) {
      result.error = "invalid or repeated function analysis order";
      return;
    }
    auto &summary = result.summaries[index];
    const auto &function = functions[index];
    auto validParameters = [&](const Expanded &source) {
      for (size_t p : source.parameters)
        if (p >= function.parameterCount) {
          result.error = "unknown parameter token";
          return false;
        }
      return result.error.empty();
    };
    for (const auto &site : function.sites) {
      if (!finished[site.callee]) {
        result.error = "callee summary not finalized";
        return;
      }
      const auto &callee = result.summaries[site.callee];
      for (size_t arg = 0; arg < site.arguments.size(); ++arg) {
        auto source = expand(site.arguments[arg], 0);
        if (!validParameters(source)) return;
        auto writes = callee.writes.find(arg);
        if (writes == callee.writes.end()) continue;
        for (const auto &object : writes->second) {
          if (source.objects.count(object) && !exempted(object))
            result.issues.push_back({FlowIssue::Kind::ArgumentWrite, index,
                                     site.id, arg, object});
          if (!root)
            for (size_t param : source.parameters)
              summary.writes[param].insert(object);
        }
      }
    }
    for (const auto &flow : function.flows) {
      auto source = expand(flow.source, 0);
      if (!validParameters(source)) return;
      if (flow.isReturn) {
        if (!root) {
          summary.returnObjects.insert(source.objects.begin(), source.objects.end());
          summary.returnParameters.insert(source.parameters.begin(), source.parameters.end());
        }
      } else {
        if (source.viaReturn.count(flow.destination) && !exempted(flow.destination))
          result.issues.push_back({FlowIssue::Kind::ReturnWrite, index,
                                   flow.node, 0, flow.destination});
        if (!root)
          for (size_t param : source.parameters)
            summary.writes[param].insert(flow.destination);
      }
    }
    finished[index] = true;
  };
  for (auto i = callerFirst.rbegin(); i != callerFirst.rend(); ++i) {
    process(*i, false);
    if (!result.error.empty()) return result;
  }
  for (size_t root : roots) {
    process(root, true);
    if (!result.error.empty()) return result;
  }
  return result;
}
} // namespace spinel::subprogram
