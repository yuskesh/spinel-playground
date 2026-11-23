#pragma once
#include "spinel/Analysis/MathInterval.h"
#include <optional>

namespace spinel::range {
enum class Form {
  Literal,
  Local,
  Computed,
  Load,
  Ktime,
  PidTgid,
  Retval,
  Kparg,
  Rawarg,
  Tpfield,
  Gload,
  Kfload
};
struct RangeValue {
  math::MathInterval interval;
  bool isBool = false;
  bool wide = false;
  Form form = Form::Computed;
};
struct Site {
  int64_t node = 0;
  int64_t rhsNode = 0;
};
struct RangeIssue {
  int64_t node;
  std::string code, message;
  // Consumer diagnostics may cross a speculative body transfer. The numerical
  // domain leaves these fields empty; they preserve an original diagnostic.
  std::string diagnosticName;
  bool unknown = false;
  std::optional<std::string> diagnosticPath;
};
struct RangeOutcome {
  RangeValue value;
  std::optional<RangeIssue> issue;
  // divMode is "u" or "floor" for the Go-compatible lowering recipe.
  std::string divMode;
};
struct MapType {
  std::string name;
  unsigned valueBits = 64;
  bool isSigned = false;
  uint64_t maxEntries = 1;
};
using Check = llvm::Expected<std::optional<RangeIssue>>;
using Environment = std::map<std::string, RangeValue>;
// Shape/type/facts consistency and SB001/SB006 are the caller's responsibility.
// Expected errors block on missing evidence/invalid API input; they are not
// SBs.
llvm::Expected<RangeOutcome> literal(math::Integer value, Site site);
llvm::Expected<RangeOutcome> transferUnary(const std::string &op,
                                           const RangeValue &value, Site site);
llvm::Expected<RangeOutcome> transferBinary(const std::string &op,
                                            const RangeValue &left,
                                            const RangeValue &right, Site site);
Check checkIntegerUse(const RangeValue &value, Site site);
Check checkArrayKey(const RangeValue &value, const MapType &map, Site site);
Check checkStoreValue(const RangeValue &value, const MapType &map, Site site,
                      const std::string &role = "value");
// Conditions use E004 math::Condition; caller marks Bool/Wide operands
// ineligible. Whole-condition rollback and common-name/Bool-kind join match Go
// narrowEnv/joinEnv.
llvm::Expected<Environment> refineEnvironment(const Environment &env,
                                              const math::Condition &condition,
                                              bool positive = true);
llvm::Expected<Environment> joinEnvironment(const Environment &left,
                                            const Environment &right);
// A local read loses literal identity even if its interval is a point.
RangeValue asLocal(RangeValue value);
} // namespace spinel::range
