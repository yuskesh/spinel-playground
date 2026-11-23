#pragma once
#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <vector>
namespace spinel::subprogram {
struct Object {
  enum class Domain { Map, Global };
  Domain domain = Domain::Map;
  size_t index = 0;
  bool operator<(const Object &other) const {
    return domain != other.domain ? domain < other.domain : index < other.index;
  }
};
struct FlowSource {
  std::set<Object> objects;
  std::set<size_t> parameters;
  std::set<int64_t> returns;
};
struct CallSite {
  int64_t id = 0;
  size_t callee = 0;
  std::vector<FlowSource> arguments;
};
struct Flow {
  int64_t node = 0;
  FlowSource source;
  bool isReturn = false;
  Object destination;
};
struct FunctionFlows {
  std::vector<CallSite> sites;
  std::vector<Flow> flows;
  size_t parameterCount = 0;
};
struct Summary {
  std::map<size_t, std::set<Object>> writes;
  std::set<Object> returnObjects;
  std::set<size_t> returnParameters;
};
struct FlowIssue {
  enum class Kind { ArgumentWrite, ReturnWrite };
  Kind kind;
  size_t caller;
  int64_t node;
  size_t argument;
  Object object;
};
struct FlowResult {
  std::vector<Summary> summaries;
  std::vector<FlowIssue> issues;
  std::string error;
};
// callerFirst excludes roots. All roots are checked after callee summaries.
// Exemptions are resolved by the consumer; only explicit Map objects may pass.
FlowResult resolveFlows(const std::vector<FunctionFlows> &functions,
                        const std::vector<size_t> &callerFirst,
                        const std::vector<size_t> &roots,
                        const std::set<Object> &exempt);
} // namespace spinel::subprogram
