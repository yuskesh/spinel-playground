#include "spinel/Analysis/RecordLayout.h"
#include <algorithm>
#include <cctype>

namespace spinel::record {
namespace {
std::string join(const std::vector<std::string> &values) {
  std::string result;
  for (const auto &value : values) {
    if (!result.empty()) result += ", ";
    result += value;
  }
  return result;
}
bool padding(const std::string &name) {
  return name.size() > 4 && name.compare(0, 4, "_pad") == 0 &&
         std::all_of(name.begin() + 4, name.end(),
                     [](unsigned char c) { return c >= '0' && c <= '9'; });
}
std::string padHint(uint64_t offset, uint64_t gap, unsigned first) {
  std::vector<std::string> parts;
  while (gap) {
    unsigned width = 4;
    while (width > 1 && (offset % width || width > gap)) width /= 2;
    parts.push_back("`_pad" + std::to_string(first++) + ": :u" +
                    std::to_string(width * 8) + "`");
    offset += width;
    gap -= width;
  }
  return join(parts);
}
} // namespace

Outcome layout(const std::string &name,
               const std::vector<std::string> &structMembers,
               const std::vector<FieldSpec> &fields) {
  Outcome result;
  result.layout.name = name;
  auto fail = [&](Site site, size_t index, std::string message) {
    result.issue = Issue{site, index, std::move(message)};
    return result;
  };
  std::vector<std::string> members;
  for (size_t i = 0; i < fields.size(); ++i) {
    const auto &field = fields[i];
    const bool pad = padding(field.name);
    if (field.count && (*field.count < 1 || *field.count > 64))
      return fail(Site::Count, i, "member " + field.name +
          ": the array length must be a literal 1..64 (bpf-mlir's record arrays) (P016)");
    if (field.count && pad)
      return fail(Site::Member, i, "padding member " + field.name +
          " cannot be an array — declare `_pad<N>` members as integers (P016)");
    unsigned bits = 0;
    if (field.type.size() >= 2 &&
        (field.type[0] == 'u' || field.type[0] == 'i')) {
      const auto width = field.type.substr(1);
      if (width == "8") bits = 8;
      else if (width == "16") bits = 16;
      else if (width == "32") bits = 32;
      else if (width == "64") bits = 64;
    }
    if (!bits)
      return fail(Site::Type, i, "member " + field.name +
          ": the type must be :u8 … :u64 or :i8 … :i64, got :" + field.type);
    members.push_back(field.name);
    result.layout.fields.push_back({field.name, field.type, bits,
        field.type[0] == 'i', pad, field.count, 0, 0});
  }
  if (members != structMembers)
    return fail(Site::Declaration, 0, "the members of BPF.record(" + name +
        ", …) (" + join(members) +
        ") must be the Struct's members in the same order (" +
        join(structMembers) + ") (P006 §1)");
  uint64_t offset = 0;
  unsigned alignment = 1, pads = 0, named = 0;
  for (size_t i = 0; i < result.layout.fields.size(); ++i) {
    auto &field = result.layout.fields[i];
    const unsigned width = field.bits / 8;
    if (offset % width) {
      const auto gap = width - offset % width;
      return fail(Site::Declaration, i, "record " + name + " has " +
          std::to_string(gap) + " implicit padding byte(s) before member " +
          field.name + " (offset " + std::to_string(offset) + ", alignment " +
          std::to_string(width) + ") — declare them before " + field.name +
          ": " + padHint(offset, gap, pads) + " (P006 §1)");
    }
    field.offset = offset;
    field.size = width * static_cast<uint64_t>(field.count.value_or(1));
    offset += field.size;
    alignment = std::max(alignment, width);
    if (field.padding) ++pads;
    else ++named;
  }
  if (offset % alignment) {
    const auto gap = alignment - offset % alignment;
    return fail(Site::Declaration, 0, "record " + name + " has " +
        std::to_string(gap) + " implicit trailing padding byte(s) (size " +
        std::to_string(offset) + ", alignment " + std::to_string(alignment) +
        ") — declare them at the end: " + padHint(offset, gap, pads) + " (P006 §1)");
  }
  if (!named)
    return fail(Site::Declaration, 0, "record " + name + " has no named member");
  result.layout.size = offset;
  result.layout.alignment = alignment;
  return result;
}
} // namespace spinel::record
