#ifndef LCA_FREESTANDING_STDLIB_H
#define LCA_FREESTANDING_STDLIB_H

#include <stddef.h>

void *malloc(size_t size);
void free(void *pointer);
__attribute__((noreturn)) void exit(int status);

#endif
