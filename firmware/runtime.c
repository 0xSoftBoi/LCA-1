// SPDX-License-Identifier: Apache-2.0
// Minimal freestanding runtime for the immutable LCA-1 firmware image.

#include <stddef.h>
#include <stdint.h>

#include "lca_mmio.h"

#define CONTEXT_SLOTS 32u
#define CONTEXT_BYTES 208u

static uint64_t context_pool[CONTEXT_SLOTS][CONTEXT_BYTES / sizeof(uint64_t)];
static uint32_t context_used;

void *memcpy(void *dest, const void *src, size_t count) {
    uint8_t *d = (uint8_t *)dest;
    const uint8_t *s = (const uint8_t *)src;
    while (count-- != 0u) {
        *d++ = *s++;
    }
    return dest;
}

void *memmove(void *dest, const void *src, size_t count) {
    uint8_t *d = (uint8_t *)dest;
    const uint8_t *s = (const uint8_t *)src;
    if (d < s) {
        while (count-- != 0u) {
            *d++ = *s++;
        }
    } else if (d > s) {
        d += count;
        s += count;
        while (count-- != 0u) {
            *--d = *--s;
        }
    }
    return dest;
}

void *memset(void *dest, int value, size_t count) {
    uint8_t *d = (uint8_t *)dest;
    while (count-- != 0u) {
        *d++ = (uint8_t)value;
    }
    return dest;
}

int memcmp(const void *left, const void *right, size_t count) {
    const uint8_t *a = (const uint8_t *)left;
    const uint8_t *b = (const uint8_t *)right;
    while (count-- != 0u) {
        if (*a != *b) {
            return (int)*a - (int)*b;
        }
        ++a;
        ++b;
    }
    return 0;
}

void *malloc(size_t size) {
    uint32_t i;
    if (size == 0u || size > CONTEXT_BYTES) {
        return NULL;
    }
    for (i = 0; i < CONTEXT_SLOTS; ++i) {
        uint32_t mask = (uint32_t)1u << i;
        if ((context_used & mask) == 0u) {
            context_used |= mask;
            memset(context_pool[i], 0, CONTEXT_BYTES);
            return context_pool[i];
        }
    }
    return NULL;
}

void free(void *pointer) {
    uintptr_t base;
    uintptr_t value;
    uint32_t slot;
    if (pointer == NULL) {
        return;
    }
    base = (uintptr_t)&context_pool[0][0];
    value = (uintptr_t)pointer;
    if (value < base || value >= base + sizeof(context_pool)) {
        return;
    }
    slot = (uint32_t)((value - base) / CONTEXT_BYTES);
    memset(context_pool[slot], 0, CONTEXT_BYTES);
    context_used &= ~((uint32_t)1u << slot);
}

__attribute__((noreturn)) void exit(int status) {
    lca_mmio_write(LCA_MAILBOX_BASE + 0x08u, 0u);
    lca_mmio_write(LCA_MAILBOX_BASE + 0x04u,
                   status == 0 ? LCA_RESULT_INTERNAL : (uint32_t)status);
    for (;;) {
    }
}

int PQCLEAN_randombytes(uint8_t *output, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        uint32_t word;
        unsigned int byte_index;
        while ((lca_mmio_read(LCA_MAILBOX_BASE + 0x1cu) & 1u) == 0u) {
        }
        word = lca_mmio_read(LCA_MAILBOX_BASE + 0x20u);
        for (byte_index = 0; byte_index < 4u && offset < count; ++byte_index) {
            output[offset++] = (uint8_t)(word >> (8u * byte_index));
        }
    }
    return 0;
}
