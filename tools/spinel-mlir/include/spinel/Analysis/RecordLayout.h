#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace spinel::record {
// Parsed declaration data only: no facts, SSA, or caller-owned references.
struct FieldSpec {
  std::string name, type;
  std::optional<int64_t> count;
};
struct FieldLayout {
  std::string name, type;
  unsigned bits = 0;
  bool isSigned = false, padding = false;
  std::optional<int64_t> count;
  uint64_t offset = 0, size = 0;
};
struct Layout {
  std::string name;
  std::vector<FieldLayout> fields;
  uint64_t size = 0;
  unsigned alignment = 1;
};
enum class Site { Declaration, Member, Type, Count };
struct Issue {
  Site site;
  size_t field;
  std::string message;
};
struct Outcome {
  Layout layout;
  std::optional<Issue> issue;
};
Outcome layout(const std::string &name,
               const std::vector<std::string> &structMembers,
               const std::vector<FieldSpec> &fields);
} // namespace spinel::record
