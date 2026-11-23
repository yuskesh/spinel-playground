package main

import "testing"

// E135 の試験 (P027): bcc の tool の root の selftest — 共有の器は e133_test.go。

// E135 の H4 / H5。
func TestBccSelftestFunclatency(t *testing.T) { bccSelftest(t, "bcc/funclatency") }
func TestBccSelftestFileslower(t *testing.T)  { bccSelftest(t, "bcc/fileslower") }
func TestBccSelftestRunqslower(t *testing.T)  { bccSelftest(t, "bcc/runqslower") }
