#include "TestAdapter.h"
#include <fstream>
#include <iostream>
#include <sstream>
#include <vector>
int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  std::ifstream in(argv[1]);
  if (!in)
    return 2;
  std::string line;
  unsigned count = 0, failed = 0;
  while (std::getline(in, line)) {
    std::vector<std::string> c;
    std::stringstream row(line);
    std::string f;
    while (std::getline(row, f, '\t'))
      c.push_back(f);
    if (c.size() != 8)
      return 2;
    auto got = spinel::math::test::evaluate(c[1], c[2], c[3], c[4], c[5], c[6]);
    ++count;
    if (got != c[7]) {
      ++failed;
      std::cerr << c[0] << ": expected " << c[7] << ", got " << got << '\n';
    }
  }
  std::cout << "cases=" << count << " failures=" << failed << '\n';
  return !count ? 2 : failed ? 1 : 0;
}
