//===- Profile.h - the profiles decision 0010 names ----------------*- C++ -*-===//
//
// 0010's profile column is an explicit kernel input recorded in the report. It
// selects each property's MODE (`observe` or `enforce`) and, where a property
// has one, an admission rule.
//
// Two of them exist here. `hosted-stage2` reproduces today's rules and adds
// only the report. `realtime` is SCOPED TO ONE ADMISSION RULE -- it admits no
// dynamic stack allocation -- because that rule is what step 2's proof of
// concept has to make real, and it needs no policy number to decide.
//
// THE OTHER ROWS OF 0010's `realtime` COLUMN READ `enforce`, AND THIS BUILD
// DOES NOT ENFORCE THEM. Each is written with its mode and `evaluated: false`,
// which says so. A consumer rule goes with that, the same one that covers
// `unknown`: under `enforce`, a property this build did not evaluate is not a
// pass. Selecting `realtime` is not a claim that the build was enforced; it is
// a claim about which column the report's modes came from.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_PROFILE_H
#define SPINEL_MLIR_CORE_PROFILE_H

namespace spinel_mlir::core {

inline constexpr const char *kHostedStage2Profile = "hosted-stage2";
inline constexpr const char *kRealtimeProfile = "realtime";

} // namespace spinel_mlir::core
#endif // SPINEL_MLIR_CORE_PROFILE_H
