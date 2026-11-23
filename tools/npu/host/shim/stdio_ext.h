#pragma once
#include <stdio.h>
size_t __fpending(FILE *);
size_t __fbufsize(FILE *);
int __freading(FILE *);
int __fwriting(FILE *);
void __fpurge(FILE *);
size_t __freadahead(FILE *);
