//===- Intrinsics.h - the CORE word intrinsics (0022, 0042) -------*- C++ -*-===//
//
// The CORE intrinsics that compute on machine words: decision 0022 §1's
// 32-bit words, and decision 0042's wrapping and unsigned forms (W1, U1).
// Every CORE route recognises them -- the checked closure behind the status
// boundary (0007), the native --core slice (0015) and freestanding kernels --
// and lowers them in place; none of them is a call into the closure.
//
// Recognition is by this table alone: a call with no receiver, the arity
// listed here, and no block, keyword or splat argument. A source that also
// defines one of these names at the top level is refused (`conflicting-
// intrinsic`): on the status lane where the closure calls it (0022's rule);
// on --core and freestanding wherever it is defined, because the prelude
// that gives the hosted half and the contract reader these names
// (tools/core/hosted-prelude.rb, Core/Prelude.h) would replace it (0042).
//
// - The 32-bit forms take Integers in the i32 range, checked before the
//   operation on a 64-bit body (a failure otherwise); a 32-bit body's values
//   are in it by construction. The comparisons answer a Boolean; every other
//   form answers the low 32 bits of its result as a signed i32.
// - The 64-bit forms (`wide`) take any Integer of a 64-bit body and are
//   refused at once on a 32-bit one, as `int64` is (decision 0019's
//   revision). They answer the low 64 bits, or a Boolean.
// - `core_u32(LIT)` (`literal`) is a constant: its argument is an Integer
//   literal in 0..2**32-1, and its value the literal's pattern read as a
//   signed i32. Any other argument is refused at compile time.
// - The shifts' counts: `core_u32_shr` takes 0..31 and `core_u64_shr` 0..63,
//   and fail otherwise; `core_w32_shl` and `core_w64_shl` take any count, as
//   Ruby's `<<` does, and answer the low bits of `a << n` (0042 S1, W1).
//
// A failure is the route's own: ARITHMETIC on the status lane, the failure
// hook with kind 4 (CoreFailKind::Intrinsic) and `failOp` on --core, and
// trap code 8 on freestanding. Its text, which --core prints and the hosted
// prelude raises, is failText.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_INTRINSICS_H
#define SPINEL_MLIR_CORE_INTRINSICS_H

#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <optional>
#include <iterator>
#include <string>
#include <string_view>

namespace spinel_mlir::core {

enum class IntrinsicOp {
  W32Add,   ///< the low 32 bits of a + b
  W32Sub,   ///< the low 32 bits of a - b
  W32Mul,   ///< the low 32 bits of a * b
  W32Neg,   ///< core_w32_sub(0, a)
  U32Lt,    ///< a < b as unsigned 32-bit words
  U32Le,    ///< a <= b as unsigned 32-bit words
  U32Gt,    ///< a > b as unsigned 32-bit words
  U32Ge,    ///< a >= b as unsigned 32-bit words
  U32Shr,   ///< a's bit pattern shifted right logically by n in 0..31
  FixedMul, ///< low32(asr(a * b, 16)) over the exact 64-bit product
  FixedDiv, ///< examples/doom/core/src/fixed.rb's fixed_div, saturating
  W32Shl,   ///< the low 32 bits of Ruby's a << n, for every n (0042)
  W64Add,   ///< the low 64 bits of a + b (0042)
  W64Sub,   ///< the low 64 bits of a - b
  W64Mul,   ///< the low 64 bits of a * b
  W64Neg,   ///< the low 64 bits of -a
  W64Shl,   ///< the low 64 bits of Ruby's a << n, for every n
  U64Lt,    ///< a < b as unsigned 64-bit words
  U64Le,    ///< a <= b as unsigned 64-bit words
  U64Gt,    ///< a > b as unsigned 64-bit words
  U64Ge,    ///< a >= b as unsigned 64-bit words
  U64Shr,   ///< a's bit pattern shifted right logically by n in 0..63
  U32Literal, ///< core_u32(LIT): LIT's 32-bit pattern, read as signed
};

struct CoreIntrinsic {
  std::string_view name;
  IntrinsicOp op;
  unsigned arity;
  bool boolean;       ///< answers a Boolean rather than an Integer
  bool wide = false;  ///< a 64-bit form: refused on a 32-bit body
  bool literal = false; ///< core_u32: a compile-time constant
  unsigned countMax = 0; ///< a shift count's bound (0..countMax), or 0
};

inline constexpr CoreIntrinsic kCoreIntrinsics[] = {
    {"core_w32_add", IntrinsicOp::W32Add, 2, false},
    {"core_w32_sub", IntrinsicOp::W32Sub, 2, false},
    {"core_w32_mul", IntrinsicOp::W32Mul, 2, false},
    {"core_w32_neg", IntrinsicOp::W32Neg, 1, false},
    {"core_u32_lt", IntrinsicOp::U32Lt, 2, true},
    {"core_u32_le", IntrinsicOp::U32Le, 2, true},
    {"core_u32_gt", IntrinsicOp::U32Gt, 2, true},
    {"core_u32_ge", IntrinsicOp::U32Ge, 2, true},
    {"core_u32_shr", IntrinsicOp::U32Shr, 2, false, false, false, 31},
    {"core_fixed_mul", IntrinsicOp::FixedMul, 2, false},
    {"core_fixed_div", IntrinsicOp::FixedDiv, 2, false},
    {"core_w32_shl", IntrinsicOp::W32Shl, 2, false},
    {"core_w64_add", IntrinsicOp::W64Add, 2, false, true},
    {"core_w64_sub", IntrinsicOp::W64Sub, 2, false, true},
    {"core_w64_mul", IntrinsicOp::W64Mul, 2, false, true},
    {"core_w64_neg", IntrinsicOp::W64Neg, 1, false, true},
    {"core_w64_shl", IntrinsicOp::W64Shl, 2, false, true},
    {"core_u64_lt", IntrinsicOp::U64Lt, 2, true, true},
    {"core_u64_le", IntrinsicOp::U64Le, 2, true, true},
    {"core_u64_gt", IntrinsicOp::U64Gt, 2, true, true},
    {"core_u64_ge", IntrinsicOp::U64Ge, 2, true, true},
    {"core_u64_shr", IntrinsicOp::U64Shr, 2, false, true, false, 63},
    {"core_u32", IntrinsicOp::U32Literal, 1, false, false, true},
};

/// The intrinsic of this name, or null.
inline const CoreIntrinsic *coreIntrinsic(std::string_view name) {
  for (const CoreIntrinsic &i : kCoreIntrinsics)
    if (i.name == name) return &i;
  return nullptr;
}

/// Whether the form checks that its operands are in the i32 range on a
/// 64-bit body: every 32-bit form but the literal.
inline bool checksI32Operands(const CoreIntrinsic &in) { return !in.wide && !in.literal; }

/// The two failures an intrinsic has, and the `op` the --core failure hook
/// is called with for each (kind 4): 32 plus the table index for an operand
/// outside the i32 range, 64 plus the index for a count outside its bound.
enum class IntrinsicFailure { Operand, Count };
inline int32_t failOp(const CoreIntrinsic &in, IntrinsicFailure f) {
  const int32_t index = static_cast<int32_t>(&in - std::begin(kCoreIntrinsics));
  return (f == IntrinsicFailure::Operand ? 32 : 64) + index;
}

/// The failure's text: what --core prints before ` (RangeError)` and what the
/// hosted prelude raises.
inline std::string failText(const CoreIntrinsic &in, IntrinsicFailure f) {
  if (f == IntrinsicFailure::Operand)
    return std::string(in.name) + ": an operand is outside the i32 range";
  return std::string(in.name) + ": the count is outside 0.." + std::to_string(in.countMax);
}

/// `core_u32(LIT)`'s value: LIT's exact value -- the reader's `bigval` text
/// when it gave one (its `value` is then saturated), else `value` -- read as
/// a 32-bit pattern, when it is in 0..2**32-1; nothing otherwise.
inline std::optional<int64_t> u32LiteralValue(int64_t value, const std::string *bigval) {
  if (bigval) {
    errno = 0;
    char *end = nullptr;
    const long long parsed = std::strtoll(bigval->c_str(), &end, 10);
    if (errno == ERANGE || !end || *end != '\0') return std::nullopt;
    value = parsed;
  }
  if (value < 0 || value > 4294967295LL) return std::nullopt;
  return value >= 2147483648LL ? value - 4294967296LL : value;
}

} // namespace spinel_mlir::core

#endif // SPINEL_MLIR_CORE_INTRINSICS_H
