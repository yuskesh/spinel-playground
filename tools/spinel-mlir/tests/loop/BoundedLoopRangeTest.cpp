#include "spinel/Analysis/BoundedLoopRange.h"
#include "llvm/Support/raw_ostream.h"
using namespace spinel;
using namespace spinel::loop;
using math::Integer;
using math::Interval;
using range::Environment;
using range::RangeValue;
static bool mutateNext = false;
static RangeValue value(int64_t lo, int64_t hi, range::Form form = range::Form::Local) {
  return {math::MathInterval(Interval(Integer::from(lo), Integer::from(hi))), false, false, form};
}
template <class T> static T take(llvm::Expected<T> result, llvm::StringRef name) {
  if (!result) {
    llvm::errs() << name << ": " << llvm::toString(result.takeError()) << "\n";
    exit(1);
  }
  return std::move(*result);
}
static void expect(bool condition, llvm::StringRef name) {
  if (!condition) { llvm::errs() << name << "\n"; exit(1); }
}
static bool is(const RangeValue &v, int64_t lo, int64_t hi) {
  auto iv = take(v.interval.finite(), "finite-query");
  return iv.lo == Integer::from(lo) && iv.hi == Integer::from(hi);
}
static Bounds bound(int64_t n, bool runtime = false) {
  return {unsigned(n), runtime, false, false};
}
int main(int argc, char **) {
  mutateNext = argc > 1;
  unsigned cases = 0;
  auto checkBound = [&](RangeValue count, bool incl, unsigned depth, unsigned product,
                        unsigned n, bool runtime, bool clamp, llvm::StringRef name) {
    auto result = take(resolveBounds(count, incl, depth, product, {1, 2}), name);
    expect(result.bounds.has_value() && !result.issue, name);
    expect(result.bounds->count == n && result.bounds->runtime == runtime &&
           result.bounds->clamp == clamp, name);
    ++cases;
  };
  checkBound(value(4,4,range::Form::Literal),false,0,1,4,false,false,"literal-four");
  checkBound(value(7,7,range::Form::Literal),true,0,1,8,false,false,"inclusive-eight");
  checkBound(value(-2,-2,range::Form::Literal),false,0,1,0,false,false,"negative-zero");
  checkBound(value(-4,11),false,0,1,11,true,true,"runtime-negative-clamp");
  checkBound(value(-4,11),true,0,1,12,true,true,"inclusive-before-clamp");
  checkBound(value(8,8,range::Form::Literal),false,1,8,8,false,false,"product-sixty-four");
  auto refusal = [&](RangeValue v, unsigned depth, unsigned product, llvm::StringRef text) {
    auto result = take(resolveBounds(v,false,depth,product,{1,2}), "bound-refusal");
    expect(!result.bounds && result.issue && result.issue->code == "SB030" &&
           result.issue->message.find(text.str()) != std::string::npos, "bound-named-refusal");
    ++cases;
  };
  refusal(value(65,65,range::Form::Literal),0,1,"runs 65 times");
  refusal(value(0,255),0,1,"upper end must be");
  refusal(value(2,2,range::Form::Literal),2,4,"at most 2 deep");
  refusal(value(8,8,range::Form::Literal),1,16,"run 128 times");
  Environment pre{{"x",value(0,0)}};
  unsigned probes = 0, checks = 0;
  auto increment = [&](const Environment &env, const Interval &iv, Mode mode)
      -> llvm::Expected<Step> {
    mode == Mode::Probe ? ++probes : ++checks;
    if (mode == Mode::Probe)
      expect(iv.isPoint(), "probe-IV-point");
    auto x = env.at("x");
    auto r = range::transferBinary("+", x, value(1,1,range::Form::Literal), {});
    if (!r) return r.takeError();
    Step step;
    step.normal = env;
    step.normal["x"] = r->value;
    step.normal["temporary"] = value(99,99);
    return step;
  };
  auto literal = take(analyzeFinite(bound(2), pre, increment), "finite-literal");
  expect(is(literal.post.at("x"),2,2) && !literal.post.count("temporary"),
         "literal-post-and-local-scope");
  expect(is(literal.checkedEntry.at("x"),0,1) &&
         literal.iv.lo == Integer::from(0) && literal.iv.hi == Integer::from(1) &&
         probes == 2 && checks == 1, "finite-probe-check-order");
  ++cases;
  auto runtime = take(analyzeFinite(bound(2,true), pre, increment), "finite-runtime");
  expect(is(runtime.post.at("x"),0,2), "runtime-includes-entry-exits");
  ++cases;
  auto withEscapes = [&](const Environment &env, const Interval &, Mode)
      -> llvm::Expected<Step> {
    Step step;
    step.normal = env; step.normal["x"] = value(1,1);
    if (!mutateNext) { auto next=env; next["x"]=value(7,7); step.nexts.push_back(next); }
    auto brk=env; brk["x"]=value(9,9); step.breaks.push_back(brk);
    return step;
  };
  auto escaped = take(analyzeFinite(bound(1), pre, withEscapes), "finite-escapes");
  expect(is(escaped.post.at("x"),1,9), "next-break-post-join");
  auto frame = take(withEscapes(pre,Interval::point(Integer::from(0)),Mode::Check), "frame");
  auto end = take(joinNormalAndNext(frame), "join-frame");
  expect(is(end.at("x"),1,7), "next-env-join");
  ++cases;
  unsigned zeroCalls=0;
  auto zeroBody = [&](const Environment &env,const Interval &iv,Mode mode)
      -> llvm::Expected<Step> {
    expect(mode==Mode::Check && iv.isPoint() && iv.lo.zero(), "zero-check-IV");
    ++zeroCalls;
    Step step; step.normal=env; step.normal["x"]=value(3,3);
    step.issues.push_back({55,"SB014","zero-loop-body-still-checked"});
    return step;
  };
  auto zero = take(analyzeFinite(bound(0), pre, zeroBody), "zero-loop");
  expect(zeroCalls==1 && zero.issues.size()==1 && is(zero.post.at("x"),0,0),
         "zero-loop-no-DCE");
  ++cases;
  auto bad = pre; bad["x"].wide=true;
  auto invalid = analyzeFinite(bound(1),bad,increment);
  expect(!invalid, "wide-local-rejected");
  llvm::consumeError(invalid.takeError());
  ++cases;
  auto missing = pre; missing["x"].interval=math::MathInterval::unknown();
  auto unknown = analyzeFinite(bound(1),missing,increment);
  expect(!unknown, "unknown-local-rejected");
  llvm::consumeError(unknown.takeError());
  ++cases;
  llvm::outs() << "E012 loop range: " << cases << " named cases GREEN\n";
}
