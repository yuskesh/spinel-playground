#pragma once
#include <sys/types.h>
typedef struct DIR DIR;
struct dirent { ino_t d_ino; char d_name[256]; };
DIR *opendir(const char *); struct dirent *readdir(DIR *); int closedir(DIR *);
void rewinddir(DIR *); long telldir(DIR *); void seekdir(DIR *, long); int dirfd(DIR *);
DIR *fdopendir(int);
