package main

import "testing"

// E139 の試験 (P027): bcc の tool の root の selftest — 共有の器は e133_test.go。

// E139 の H4 / H5 (deadlock・gethostlatency は H0 で波 2)。
func TestBccSelftestMemleak(t *testing.T) { bccSelftest(t, "bcc/memleak") }
