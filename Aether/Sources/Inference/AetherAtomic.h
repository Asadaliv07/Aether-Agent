#ifndef AetherAtomic_h
#define AetherAtomic_h

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a heap-allocated C11 atomic boolean flag.
typedef struct AetherAtomicFlag AetherAtomicFlag;

/// Creates and initializes an atomic boolean flag to false.
AetherAtomicFlag * aether_atomic_flag_create(void);

/// Sets the atomic boolean flag value with memory_order_release semantics.
void aether_atomic_flag_set(AetherAtomicFlag * flag, bool val);

/// Gets the current atomic boolean flag value with memory_order_acquire semantics.
bool aether_atomic_flag_get(const AetherAtomicFlag * flag);

/// Frees the atomic boolean flag memory.
void aether_atomic_flag_destroy(AetherAtomicFlag * flag);

/// Abort callback function conforming to ggml_abort_callback signature: bool (*)(void * data).
/// Returns true if the referenced atomic flag is set to true.
bool aether_abort_callback(void * data);

#ifdef __cplusplus
}
#endif

#endif /* AetherAtomic_h */
