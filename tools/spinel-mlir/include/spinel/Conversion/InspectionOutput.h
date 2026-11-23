#pragma once
namespace spinel {
// Separate opt-in CLI path; legacy command parsing/publication is unchanged.
int printBuildInfo();
int runInspectionCLI(int argc, char **argv);
}
