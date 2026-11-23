#include "spinel/Analysis/BoundedLoopRange.h"
namespace spinel::loop {
namespace {
using range::Environment;
using math::Integer;
using math::Interval;
llvm::Error validEnvironment(const Environment &env) {
  for (const auto &[name,value] : env) {
    if (value.wide) return math::fail(math::Failure::InvalidTransfer);
    if (!value.isBool) {
      auto iv=value.interval.finite();
      if (!iv) return iv.takeError();
    }
  }
  return llvm::Error::success();
}
Environment keepKeys(const Environment &env,const Environment &pre) {
  Environment result;
  for (const auto &[name,value] : pre) {
    auto found=env.find(name);
    result.emplace(name,found==env.end()?value:found->second);
  }
  return result;
}
BoundOutcome refused(int64_t node,const std::string &message) {
  return {std::nullopt,range::RangeIssue{node,"SB030",message}};
}
} // namespace
llvm::Expected<BoundOutcome> resolveBounds(
    const range::RangeValue &count,bool inclusive,unsigned depth,
    unsigned product,range::Site site) {
  if (depth>=2)
    return refused(site.node,"loops nest at most 2 deep on the eBPF side (bpf-mlir's ebpf.loop) — move the innermost loop out (P015)");
  if (product>64) return math::fail(math::Failure::InvalidTransfer);
  if (count.isBool || count.wide)
    return refused(site.rhsNode,"the loop count must be an Integer (P015)");
  auto value=count.interval.finite();
  if (!value) return value.takeError();
  bool literal=count.form==range::Form::Literal;
  if (literal && !value->isPoint()) return math::fail(math::Failure::InvalidTransfer);
  if (inclusive) {
    auto incremented=math::add(*value,Interval::point(Integer::from(1)));
    if (!incremented) return incremented.takeError();
    value=std::move(incremented);
  }
  auto limit=Integer::from(64);
  if (limit<value->hi) {
    if (literal)
      return refused(site.node,"the loop runs "+value->hi.str()+
        " times — bpf-mlir's ebpf.loop runs at most 64; split the work or narrow it (P015)");
    std::string what=inclusive?"count (m + 1)":"count";
    return refused(site.rhsNode,"the loop "+what+" has range "+value->str()+
      " — its upper end must be ≤ 64 for bpf-mlir's ebpf.loop: show it in the range, e.g. "
      "`k & 63`, `k % 64` or inside `if k <= 64` (P015・P017)");
  }
  unsigned n=0;
  // The mathematical upper endpoint has been checked before the conversion.
  if (Integer::from(0)<value->hi && llvm::StringRef(value->hi.str()).getAsInteger(10,n))
    return math::fail(math::Failure::InvalidInteger);
  if (product*n>64)
    return refused(site.node,"the nested loops run "+std::to_string(product*n)+
      " times in all — bpf-mlir's ebpf.loop allows a product ≤ 64; shrink one of the counts (P015)");
  return BoundOutcome{Bounds{n,!literal,!literal && inclusive,
                             !literal && value->lo.negative()},std::nullopt};
}
llvm::Expected<range::Environment> joinNormalAndNext(const Step &step) {
  if (auto error=validEnvironment(step.normal)) return std::move(error);
  auto end=step.normal;
  for (const auto &next : step.nexts) {
    if (auto error=validEnvironment(next)) return std::move(error);
    auto joined=range::joinEnvironment(end,next);
    if (!joined) return joined.takeError();
    end=std::move(*joined);
  }
  return end;
}
llvm::Expected<Result> analyzeFinite(const Bounds &bounds,
    const range::Environment &pre,BodyTransfer body) {
  if (bounds.count>64) return math::fail(math::Failure::InvalidTransfer);
  if (auto error=validEnvironment(pre)) return std::move(error);
  Environment entry=pre;
  std::vector<Environment> entries,exits;
  for (unsigned j=0;j<bounds.count;++j) {
    entries.push_back(entry);
    if (bounds.runtime) exits.push_back(entry);
    auto step=body(entry,Interval::point(Integer::from(j)),Mode::Probe);
    if (!step) return step.takeError();
    for (const auto &brk : step->breaks) {
      if (auto error=validEnvironment(brk)) return std::move(error);
      exits.push_back(brk);
    }
    auto end=joinNormalAndNext(*step);
    if (!end) return end.takeError();
    entry=keepKeys(*end,pre);
    // Speculative issues are discarded. The checked hull is visited once below.
  }
  exits.push_back(entry);
  Environment all=pre;
  if (!entries.empty()) {
    all=entries.front();
    for (size_t i=1;i<entries.size();++i) {
      auto joined=range::joinEnvironment(all,entries[i]);
      if (!joined) return joined.takeError();
      all=std::move(*joined);
    }
  }
  Interval iv=Interval::point(Integer::from(0));
  if (bounds.count) iv=Interval(Integer::from(0),Integer::from(bounds.count-1));
  auto checked=body(all,iv,Mode::Check);
  if (!checked) return checked.takeError();
  Environment post=exits.front();
  for (size_t i=1;i<exits.size();++i) {
    auto joined=range::joinEnvironment(post,exits[i]);
    if (!joined) return joined.takeError();
    post=std::move(*joined);
  }
  return Result{std::move(all),keepKeys(post,pre),std::move(iv),
                std::move(checked->issues)};
}
} // namespace spinel::loop
