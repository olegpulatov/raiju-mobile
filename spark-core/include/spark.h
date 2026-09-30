#ifndef RAIJU_SPARK_H
#define RAIJU_SPARK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Strings returned by command/poll are UTF-8 allocations owned by the caller. */
uint64_t spark_create(void);
char *spark_command(uint64_t handle, const char *json);
char *spark_poll_event(uint64_t handle);
void spark_string_free(char *value);
/* Input is mono float32 PCM at 16 kHz. Invalid/stale handles are no-ops. */
void spark_push_audio(uint64_t handle, const float *samples, size_t count);
/* Output is mono float32 PCM at 48 kHz; returns samples copied. */
size_t spark_read_audio(uint64_t handle, float *samples, size_t capacity);
/* Idempotent. A destroyed handle is never reused during this process. */
void spark_destroy(uint64_t handle);

#ifdef __cplusplus
}
#endif
#endif
