/* smoke.c — a C host of libblobly: loads the library at run time, brings sim-demo up, hears
 * its simulated ECUs on inproc:CAN1, sends a frame, and does the same from a thread the HOST
 * created — the one the V runtime's collector did not see born — then stops and starts again.
 *
 *   gcc -o build/bb_smoke cmd/libblobly/smoke.c -ldl -lpthread   (Linux)
 *   build/bb_smoke build/libblobly.so projects/sim-demo.blobnet
 *
 * Exit 0 only when every step held; each failure names the step and bb_last_error. */
#include <stdio.h>
#include <string.h>
#include "bb.h"

#ifdef _WIN32
#include <windows.h>
typedef HMODULE lib_t;
static lib_t lib_open(const char *p) { return LoadLibraryA(p); }
static void *lib_sym(lib_t l, const char *n) { return (void *)GetProcAddress(l, n); }
#else
#include <dlfcn.h>
#include <pthread.h>
typedef void *lib_t;
static lib_t lib_open(const char *p) { return dlopen(p, RTLD_NOW); }
static void *lib_sym(lib_t l, const char *n) { return dlsym(l, n); }
#endif

typedef const char *(*str_fn)(void);
typedef int (*int_fn)(void);
typedef int (*str_int_fn)(const char *);
typedef const char *(*idx_str_fn)(int);
typedef int (*send_fn)(int, const bb_frame *);
typedef int (*recv_fn)(int, int, bb_frame *);
typedef int (*int_int_fn)(int);
static int_fn bb_thread_attach_p, bb_thread_detach_p;

static str_fn bb_version_p, bb_last_error_p;
static int_fn bb_init_p, bb_start_p, bb_stop_p, bb_channel_count_p;
static str_int_fn bb_load_p, bb_bus_open_p;
static idx_str_fn bb_channel_name_p, bb_channel_iface_p;
static send_fn bb_bus_send_p;
static recv_fn bb_bus_recv_p;
static int_int_fn bb_bus_health_p, bb_bus_close_p;

#define FAIL(step) do { fprintf(stderr, "FAIL %s: %s\n", step, bb_last_error_p()); return 1; } while (0)

/* hear n frames and send one, on a handle of this thread's own */
static int exchange(const char *who, int n) {
	int h = bb_bus_open_p("inproc:CAN1");
	if (h < 0) { fprintf(stderr, "FAIL %s open: %s\n", who, bb_last_error_p()); return 1; }
	bb_frame f;
	for (int i = 0; i < n; i++) {
		int rc = bb_bus_recv_p(h, 1000, &f);
		if (rc != 0) { fprintf(stderr, "FAIL %s recv %d: rc=%d %s\n", who, i, rc, bb_last_error_p()); return 1; }
	}
	memset(&f, 0, sizeof f);
	f.id = 0x123; f.len = 3; f.data[0] = 1; f.data[1] = 2; f.data[2] = 3;
	if (bb_bus_send_p(h, &f) != 0) { fprintf(stderr, "FAIL %s send: %s\n", who, bb_last_error_p()); return 1; }
	if (bb_bus_health_p(h) != BB_HEALTH_UNKNOWN) { fprintf(stderr, "FAIL %s health: a software bus has no ladder\n", who); return 1; }
	if (bb_bus_close_p(h) != 0) { fprintf(stderr, "FAIL %s close: %s\n", who, bb_last_error_p()); return 1; }
	if (bb_bus_recv_p(h, 0, &f) != BB_ERR_HANDLE) { fprintf(stderr, "FAIL %s: a closed handle must refuse\n", who); return 1; }
	printf("ok   %s: %d frames heard, one sent\n", who, n);
	return 0;
}

#ifndef _WIN32
#include <time.h>
/* blocks in an unbounded recv on a quiet wire until the main thread closes the handle */
static int quiet_handle;
static void *blocked_recv(void *arg) {
	(void)arg;
	static int rc;
	if (bb_thread_attach_p() != 0) { rc = 99; return &rc; }
	bb_frame f;
	rc = bb_bus_recv_p(quiet_handle, -1, &f);
	bb_thread_detach_p();
	return &rc;
}

/* A thread the host created: the V runtime's collector did not see it born. Short-lived handles
 * first, so that a COLLECTION happens on this thread (an unregistered thread collecting is
 * Boehm's "Collecting from unknown thread" abort: measured at 10 churns, 3 of 3 runs, and
 * survived at 5 — 200 is the margin) — then the exchange. */
static void *host_thread(void *arg) {
	(void)arg;
	static int rc;
	if (bb_thread_attach_p() != 0) { fprintf(stderr, "FAIL attach: %s\n", bb_last_error_p()); rc = 1; return &rc; }
	for (int i = 0; i < 200; i++) {
		int h = bb_bus_open_p("inproc:CAN1");
		if (h < 0 || bb_bus_close_p(h) != 0) { fprintf(stderr, "FAIL host thread churn %d: %s\n", i, bb_last_error_p()); rc = 1; return &rc; }
	}
	rc = exchange("host thread", 20);
	if (bb_thread_detach_p() != 0) { fprintf(stderr, "FAIL detach: %s\n", bb_last_error_p()); rc = 1; }
	return &rc;
}
#endif

int main(int argc, char **argv) {
	if (argc < 3) { fprintf(stderr, "usage: bb_smoke <libblobly.so> <project.blobnet>\n"); return 2; }
	lib_t lib = lib_open(argv[1]);
	if (!lib) { fprintf(stderr, "FAIL load %s\n", argv[1]); return 1; }
#define SYM(name) do { name##_p = lib_sym(lib, #name); if (!name##_p) { fprintf(stderr, "FAIL symbol %s\n", #name); return 1; } } while (0)
	SYM(bb_version); SYM(bb_init); SYM(bb_last_error); SYM(bb_thread_attach); SYM(bb_thread_detach); SYM(bb_load); SYM(bb_start); SYM(bb_stop);
	SYM(bb_channel_count); SYM(bb_channel_name); SYM(bb_channel_iface);
	SYM(bb_bus_open); SYM(bb_bus_send); SYM(bb_bus_recv); SYM(bb_bus_health); SYM(bb_bus_close);

	if (bb_init_p() != 0) FAIL("init");
	if (bb_thread_attach_p() != 0) FAIL("attach on the loading thread must be harmless");
	printf("libblobly %s\n", bb_version_p());
	if (bb_start_p() != BB_ERR_STATE) { fprintf(stderr, "FAIL start before load must refuse\n"); return 1; }
	if (bb_load_p(argv[2]) != 0) FAIL("load");
	int n = bb_channel_count_p();
	if (n < 2) { fprintf(stderr, "FAIL channels: %d\n", n); return 1; }
	for (int i = 0; i < n; i++) printf("     channel %s (%s)\n", bb_channel_name_p(i), bb_channel_iface_p(i));
	if (bb_start_p() != 0) FAIL("start");
	if (bb_start_p() != BB_ERR_STATE) { fprintf(stderr, "FAIL a second start must refuse\n"); return 1; }

	if (exchange("main thread", 20)) return 1;
#ifndef _WIN32
	pthread_t t;
	if (pthread_create(&t, NULL, host_thread, NULL) != 0) { fprintf(stderr, "FAIL pthread_create\n"); return 1; }
	int *rc;
	pthread_join(t, (void **)&rc);
	if (*rc) return 1;
	/* a close on this thread ends an unbounded recv on another, as BB_ERR_HANDLE */
	quiet_handle = bb_bus_open_p("inproc:BB_SMOKE_QUIET");
	if (quiet_handle < 0) FAIL("open quiet");
	pthread_t q;
	pthread_create(&q, NULL, blocked_recv, NULL);
	struct timespec ts = {0, 100 * 1000 * 1000};
	nanosleep(&ts, NULL);
	if (bb_bus_close_p(quiet_handle) != 0) FAIL("close under a blocked recv");
	int *qrc;
	pthread_join(q, (void **)&qrc);
	if (*qrc != BB_ERR_HANDLE) { fprintf(stderr, "FAIL a closed handle's blocked recv: rc=%d\n", *qrc); return 1; }
	printf("ok   a close ended a blocked recv on another thread\n");
#endif
	/* -1 is a handle no open returned: refused and named, not read as 4294967295 (V3's int is
	 * 64 bits, C's 32) */
	if (bb_bus_close_p(-1) != BB_ERR_HANDLE) { fprintf(stderr, "FAIL close(-1)\n"); return 1; }
	if (strstr(bb_last_error_p(), "-1") == NULL) { fprintf(stderr, "FAIL close(-1) names: %s\n", bb_last_error_p()); return 1; }
	(void)bb_version_p();
	if (bb_last_error_p()[0] != 0) { fprintf(stderr, "FAIL a success leaves the error empty\n"); return 1; }
	printf("ok   handle -1 refused by name; a success clears the error\n");
	if (bb_stop_p() != 0) FAIL("stop");
	if (bb_stop_p() != BB_ERR_STATE) { fprintf(stderr, "FAIL a second stop must refuse\n"); return 1; }
	/* the process is free again: the same project starts a second time */
	if (bb_start_p() != 0) FAIL("start again");
	if (exchange("second run", 5)) return 1;
	if (bb_stop_p() != 0) FAIL("stop again");
	printf("ok   libblobly smoke\n");
	return 0;
}
