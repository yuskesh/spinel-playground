package main

import "testing"

// E134 の試験 (P027): bcc の tool の root の selftest — 共有の器は e133_test.go。

// E134 の H4 / H5。
func TestBccSelftestCpudist(t *testing.T)     { bccSelftest(t, "bcc/cpudist") }
func TestBccSelftestHardirqs(t *testing.T)    { bccSelftest(t, "bcc/hardirqs") }
func TestBccSelftestSoftirqs(t *testing.T)    { bccSelftest(t, "bcc/softirqs") }
func TestBccSelftestSlabratetop(t *testing.T) { bccSelftest(t, "bcc/slabratetop") }
