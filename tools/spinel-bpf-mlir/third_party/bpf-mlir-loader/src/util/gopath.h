/* util/gopath.h — Go の path/filepath (Unix) の Clean・Join・Abs の写し (E055)。結果は malloc (失敗は NULL) */
#ifndef BML_GOPATH_H
#define BML_GOPATH_H

#include <stddef.h>

/* filepath.Clean */
char *bml_go_path_clean(const char *path);
/* filepath.Join (空の要素は飛ばし、全てが空なら "") */
char *bml_go_path_join(const char *const *elem, size_t n);
/* filepath.Abs (相対は getcwd と Join、絶対は Clean) — getcwd の失敗は NULL */
char *bml_go_path_abs(const char *path);

#endif
