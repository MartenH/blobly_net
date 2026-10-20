/* gc_attach.h — what bb_thread_attach/detach need from Boehm, declared here because V's
 * generated C declares the collector's functions itself and includes no gc.h: GC_stack_base is
 * `void *mem_base` alone on every target this builds for (a second field exists on ia64/e2k
 * only), which is also what V's builtin assumes of it. */
#ifndef BLOBLY_GC_ATTACH_H
#define BLOBLY_GC_ATTACH_H
struct bb_stack_base { void *mem_base; };
int GC_get_stack_base(void *sb);
int GC_register_my_thread(void *sb);
int GC_unregister_my_thread(void);
#endif
