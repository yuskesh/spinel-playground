/* E009 shim: WASI has no <fnmatch.h> (pure-computation; portable impl exists) */
#define FNM_NOMATCH 1
#define FNM_PATHNAME 1
#define FNM_PERIOD 4
#define FNM_NOESCAPE 2
#define FNM_CASEFOLD 16
int fnmatch(const char *, const char *, int);
