// Deliberately wrong algorithms live only in this test executable.
#include "TestAdapter.h"
#include <iostream>
using namespace spinel::math;
int main() {
  unsigned detected = 0;
  auto observe = [&](const char *name, const std::string &baseline,
                     const std::string &mutant) {
    bool differs = baseline != mutant;
    detected += differs;
    std::cout << name << " baseline=" << baseline << " mutant=" << mutant
              << " detected=" << differs << '\n';
  };
  observe("truncate-division",
          test::evaluate("floor", "-7", "-7", "0", "0", "2"),
          llvm::cantFail(
              Integer::divide(Integer::from(-7), Integer::from(2), false))
              .str());
  // Simulate the premature i64 result wrap using the actual fixed-width APInt.
  llvm::APInt a(64, 9223372036854775807ULL), one(64, 1);
  llvm::SmallString<30> wrapped;
  (a + one).toStringSigned(wrapped);
  observe("pretruncate-i64",
          test::evaluate("add", "9223372036854775807", "9223372036854775807",
                         "1", "1", "-"),
          "[" + std::string(wrapped) + ", " + std::string(wrapped) + "]");
  observe("suppress-empty-arm",
          test::evaluate("narrow", "0", "5", "0", "0", "<:-4"), "suppressed");
  observe("drop-join-arm", test::evaluate("join", "-9", "-2", "3", "8", "-"),
          "[-9, -2]");
  return detected == 4 ? 0 : 1;
}
