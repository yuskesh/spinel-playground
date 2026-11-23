#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace spinel {
struct Inspection {
  bool domainProduced = false;
  std::string domain;
};
struct UprobeTarget {
  std::string name, kind, binaryPath, declFile;
  unsigned declLine = 0, declCol = 0;
};
namespace inspection {
struct Position {
  std::string file;
  unsigned line = 0, col = 0;
};
struct Root {
  std::string name, kind;
  Position decl, def;
};
struct Function {
  std::string name;
  std::vector<std::string> membership;
};
struct Edge {
  std::string from, to;
  Position pos;
  std::string dispatch;
};
struct Diagnostic {
  std::string verdict, code, name;
  Position pos;
  std::vector<std::string> path;
  std::string message;
};
struct Domain {
  std::string source;
  std::vector<Root> roots;
  std::vector<Function> functions;
  std::vector<Edge> edges;
  std::vector<Diagnostic> diagnostics;
};
// encoding/json's default string representation, including HTML escaping.
std::string quote(const std::string &);
// The input collections have their semantic Go order already established.
std::string writeDomain(const Domain &);
} // namespace inspection
} // namespace spinel
