#include "AetherAtomic.h"
#include <stdatomic.h>
#include <stdlib.h>

struct AetherAtomicFlag {
    atomic_bool value;
};

AetherAtomicFlag * aether_atomic_flag_create(void) {
    AetherAtomicFlag * flag = (AetherAtomicFlag *)malloc(sizeof(AetherAtomicFlag));
    if (flag) {
        atomic_init(&flag->value, false);
    }
    return flag;
}

void aether_atomic_flag_set(AetherAtomicFlag * flag, bool val) {
    if (flag) {
        atomic_store_explicit(&flag->value, val, memory_order_release);
    }
}

bool aether_atomic_flag_get(const AetherAtomicFlag * flag) {
    if (flag) {
        return atomic_load_explicit(&flag->value, memory_order_acquire);
    }
    return false;
}

void aether_atomic_flag_destroy(AetherAtomicFlag * flag) {
    free(flag);
}

bool aether_abort_callback(void * data) {
    if (!data) {
        return false;
    }
    return aether_atomic_flag_get((const AetherAtomicFlag *)data);
}
