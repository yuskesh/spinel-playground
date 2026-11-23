#include "spinel/Analysis/SubprogramFlow.h"
#include <cstdlib>
#include <iostream>
using namespace spinel::subprogram;
static void check(bool ok, const char *name) {
  if (!ok) { std::cerr << "FAIL " << name << '\n'; std::exit(1); }
  std::cout << "PASS " << name << '\n';
}
int main() {
  Object map{Object::Domain::Map, 0}, global{Object::Domain::Global, 0};
  FlowSource read; read.objects.insert(map);
  FlowSource parameter; parameter.parameters.insert(0);
  std::vector<FunctionFlows> f(3);
  // root reads a map and passes the result through relay to put.
  f[0].sites.push_back({10, 1, {read}});
  f[1].parameterCount = 1;
  f[1].sites.push_back({11, 2, {parameter}});
  f[2].parameterCount = 1;
  f[2].flows.push_back({12, parameter, false, map});
  auto r = resolveFlows(f, {1, 2}, {0}, {});
  check(r.error.empty() && r.issues.size() == 1 &&
            r.issues[0].kind == FlowIssue::Kind::ArgumentWrite &&
            r.issues[0].caller == 0 && r.issues[0].node == 10,
        "argument-write-summary-crosses-relay");
  check(r.summaries.size() == 3 && r.summaries[1].writes[0].count(map),
        "callee-first-summary-reaches-caller");
  check(resolveFlows(f, {1, 2}, {0}, {map}).issues.empty(),
        "explicit-percpu-map-exemption");
  f[2].flows[0].destination = global;
  check(resolveFlows(f, {1, 2}, {0}, {}).issues.empty(),
        "map-zero-does-not-alias-global-zero");
  FlowSource globalRead; globalRead.objects.insert(global);
  f[0].sites[0].arguments[0] = globalRead;
  check(resolveFlows(f, {1, 2}, {0}, {global}).issues.size() == 1,
        "counter-is-never-percpu-exempt");
  // Reading helper returns a map read; root writes that result back.
  std::vector<FunctionFlows> returns(2);
  returns[1].flows.push_back({21, read, true, {}});
  returns[0].sites.push_back({20, 1, {}});
  FlowSource returned; returned.returns.insert(20);
  returns[0].flows.push_back({22, returned, false, map});
  auto ret = resolveFlows(returns, {1}, {0}, {});
  check(ret.error.empty() && ret.issues.size() == 1 &&
            ret.issues[0].kind == FlowIssue::Kind::ReturnWrite &&
            ret.issues[0].node == 22,
        "returned-map-read-reaches-root-write");
  // An identity helper returns its caller's argument provenance.
  returns[1].parameterCount = 1;
  returns[1].flows[0].source = parameter;
  returns[0].sites[0].arguments = {read};
  check(resolveFlows(returns, {1}, {0}, {}).issues.size() == 1,
        "returned-parameter-relays-caller-map-read");
  returned.returns = {999};
  returns[0].flows[0].source = returned;
  check(!resolveFlows(returns, {1}, {0}, {}).error.empty(),
        "unknown-call-token-fails-closed");
}
