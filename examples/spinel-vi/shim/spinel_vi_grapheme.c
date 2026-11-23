/* Pinned libgrapheme 3.0.0 minimal implementation surface for E105.
 * character.c needs util.c and utf8.c plus its generated character table;
 * do not pull case/word/line/bidi modules into the editor binary. */
#include "../vendor/libgrapheme/src/util.c"
#include "../vendor/libgrapheme/src/utf8.c"
#include "../vendor/libgrapheme/src/character.c"
