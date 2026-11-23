#pragma once
#include "llvm/Support/Error.h"
#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <tuple>
#include <vector>
namespace spinel::consumer {
// Owned observations: no Operation, SSA value, or mutable run state.
struct ProbeSpan {
  std::string file;
  int64_t line=0,col=0,endLine=0,endCol=0;
  std::string kind;
  auto key() const {return std::tie(file,line,col,endLine,endCol,kind);}
  bool operator<(const ProbeSpan &other) const {return key()<other.key();}
};
struct ProbeDifference {ProbeSpan span;std::string message;};
llvm::Expected<std::vector<ProbeDifference>> compareTypingProbe(
  const std::string &before,const std::string &after,const std::string &file,
  int64_t userLines,const std::set<std::string> &roots,
  const std::set<ProbeSpan> &dependent,
  const std::set<std::string> &sourcePaths = {});
struct ProbeNode {
  ProbeSpan span;std::string name;
  std::map<std::string,int64_t> refs;
  std::map<std::string,std::vector<int64_t>> arrays;
};
llvm::Expected<std::set<ProbeSpan>> typingProbeDependencies(
  const std::map<int64_t,ProbeNode> &nodes,
  const std::map<std::string,int64_t> &topDefs,
  const std::set<std::string> &roots);
}
