#include "spinel/Analysis/KernelTypes.h"
#include <iostream>
using namespace spinel;
int main() {
  unsigned checks = 0, failures = 0;
  auto check = [&](const char *name, bool ok) {
    ++checks;
    if (!ok) { ++failures; std::cerr << "FAIL " << name << '\n'; }
  };
  struct Row { unsigned bits; bool sign; const char *lo, *hi; };
  const Row rows[] = {
    {8,true,"-128","127"}, {8,false,"0","255"},
    {16,true,"-32768","32767"}, {16,false,"0","65535"},
    {32,true,"-2147483648","2147483647"}, {32,false,"0","4294967295"},
    {64,true,"-9223372036854775808","9223372036854775807"},
    {64,false,"0","18446744073709551615"}
  };
  for (const auto &row : rows) {
    auto value = tracing::integerRange(row.bits, row.sign, tracing::IntegerSource::KernelField);
    if (!value) { llvm::consumeError(value.takeError()); check("valid-type", false); continue; }
    auto interval = llvm::cantFail(value->interval.finite());
    check("endpoints", interval.lo.str() == row.lo && interval.hi.str() == row.hi);
    check("field-wide", value->wide == (row.bits == 64 && !row.sign));
    check("field-form", value->form == range::Form::Kfload);
  }
  auto read = tracing::integerRange(64, false, tracing::IntegerSource::KernelRead);
  check("read-u64-not-wide", read && !read->wide && llvm::cantFail(read->interval.finite()).hi.str() == "18446744073709551615");
  if (!read) llvm::consumeError(read.takeError());
  auto arg = tracing::integerRange(16, false, tracing::IntegerSource::Argument);
  check("arg-u16", arg && arg->form == range::Form::Kparg && llvm::cantFail(arg->interval.finite()).str() == "[0, 65535]");
  if (!arg) llvm::consumeError(arg.takeError());
  auto ptr = tracing::integerRange(64, true, tracing::IntegerSource::Argument);
  check("ptr-argument-signed-i64", ptr && !ptr->wide && !ptr->isBool &&
      ptr->form == range::Form::Kparg &&
      llvm::cantFail(ptr->interval.finite()).str() == "[-9223372036854775808, 9223372036854775807]");
  if (!ptr) llvm::consumeError(ptr.takeError());
  auto ret = tracing::integerRange(64, false, tracing::IntegerSource::KprobeReturn);
  check("kretval-not-retval-form", ret && ret->wide && ret->form == range::Form::Computed);
  if (!ret) llvm::consumeError(ret.takeError());
  auto status = tracing::readStatusRange();
  check("read-status", llvm::cantFail(status.interval.finite()).str() == "[-9223372036854775808, 0]" && !status.wide);
  auto bad = tracing::integerRange(33, true, tracing::IntegerSource::KernelField);
  check("invalid-width-blocking", !bad);
  if (!bad) llvm::consumeError(bad.takeError());
  std::cout << "checks=" << checks << " failures=" << failures << '\n';
  return failures ? 1 : 0;
}
