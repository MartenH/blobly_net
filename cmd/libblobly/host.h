/* host.h — the C side of what the V library cannot say itself: per-THREAD state, and Boehm's
 * registration of a thread it did not create.
 *
 * The error buffer and the attached flag are thread-local, so bb_last_error is the calling
 * thread's own (a worker's timeout cannot overwrite the driver thread's refusal) and detach
 * knows whether THIS thread is one attach registered — GC_unregister_my_thread answers
 * success for any thread and deletes the loading thread's record if asked (measured: a core
 * dump on the next call).
 *
 * V's generated C declares the collector's functions itself and includes no gc.h, so the stack
 * base is declared here: `void *mem_base` alone on every target this builds for (a second field
 * exists on ia64/e2k only), which is also what V's builtin assumes of it. */
#ifndef BLOBLY_HOST_H
#define BLOBLY_HOST_H
#include <string.h>

#if defined(_MSC_VER)
#define BB_THREAD_LOCAL __declspec(thread)
#else
#define BB_THREAD_LOCAL _Thread_local
#endif

static BB_THREAD_LOCAL char bb_err_buf[512];
static BB_THREAD_LOCAL int bb_attached_here;

static inline void bb_err_set(const char *s) {
	strncpy(bb_err_buf, s, sizeof bb_err_buf - 1);
	bb_err_buf[sizeof bb_err_buf - 1] = 0;
}
static inline const char *bb_err_get(void) { return bb_err_buf; }
static inline int bb_attached(void) { return bb_attached_here; }
static inline void bb_set_attached(int v) { bb_attached_here = v; }

struct bb_stack_base { void *mem_base; };
int GC_get_stack_base(void *sb);
int GC_register_my_thread(void *sb);
int GC_unregister_my_thread(void);
#endif
