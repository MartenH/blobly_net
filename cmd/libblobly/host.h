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

static BB_THREAD_LOCAL char bb_err_buf[BB_ERROR_MAX + 1];
static BB_THREAD_LOCAL int bb_attached_here;
/* the NRC of the thread's last call when it failed with a negative response, else -1: reset by
 * every call (bb_err_set), so it is that call's alone (bb_last_nrc) */
static BB_THREAD_LOCAL int bb_nrc_here = -1;

/* a message longer than BB_ERROR_MAX bytes is cut before the character the bound falls in, never
 * inside its UTF-8 sequence: a host decoding it strictly must not fail on our truncation. At most
 * three bytes back — a character has no more continuation bytes than that — so bytes that are not
 * UTF-8 at all cannot walk the cut to an empty message */
static inline void bb_err_set(const char *s) {
	bb_nrc_here = -1;
	size_t n = strlen(s);
	if (n > BB_ERROR_MAX) {
		n = BB_ERROR_MAX;
		for (int back = 0; back < 3 && n > 0 && ((unsigned char)s[n] & 0xC0) == 0x80; back++) n--;
	}
	memcpy(bb_err_buf, s, n);
	bb_err_buf[n] = 0;
}
static inline const char *bb_err_get(void) { return bb_err_buf; }
static inline int bb_attached(void) { return bb_attached_here; }
static inline void bb_nrc_set(int v) { bb_nrc_here = v; }
static inline int bb_nrc_get(void) { return bb_nrc_here; }
static inline void bb_set_attached(int v) { bb_attached_here = v; }

struct bb_stack_base { void *mem_base; };
int GC_get_stack_base(void *sb);
int GC_register_my_thread(void *sb);
int GC_unregister_my_thread(void);
#endif
