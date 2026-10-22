/* smoke.c — a C host of libblobly: loads the library at run time, brings sim-demo up, hears
 * its simulated ECUs on inproc:CAN1, sends a frame, and does the same from a thread the HOST
 * created — the one the V runtime's collector did not see born — encodes and decodes through
 * CAN1's database (dbc/blobly_net.dbc), arms and clears a fault and stamps an E2E Profile 1
 * frame, then stops and starts again.
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
typedef int (*msg_info_fn)(int, int, bb_message *);
typedef int (*msg_str_fn)(int, int, char *, int);
typedef int (*sig_info_fn)(int, int, int, bb_signal *);
typedef int (*sig_str_fn)(int, int, int, char *, int);
typedef int (*sig_label_fn)(int, int, int, int, uint64_t *, double *, char *, int);
typedef int (*encode_fn)(int, int, int, const char *const *, const double *, bb_frame *);
typedef int (*decode_fn)(int, const bb_frame *, int *, double *, uint8_t *, int);
typedef int (*fault_fn)(int, const char *, const char *, const char *, int, const char *);
typedef int (*p01_crc_fn)(const uint8_t *, int, int, int, int, const char *);
typedef int (*p01_protect_fn)(uint8_t *, int, int, int, int, int, const char *);
static fault_fn bb_sim_fault_p;
static int_fn bb_sim_clear_faults_p;
static p01_crc_fn bb_e2e_p01_crc_p;
static p01_protect_fn bb_e2e_p01_protect_p;
static int_fn bb_thread_attach_p, bb_thread_detach_p;
static int_int_fn bb_message_count_p;
static msg_info_fn bb_message_info_p;
static msg_str_fn bb_message_name_p;
static sig_info_fn bb_signal_info_p;
static sig_str_fn bb_signal_name_p, bb_signal_unit_p;
static sig_label_fn bb_signal_label_p;
static encode_fn bb_encode_p;
static decode_fn bb_decode_p;

static str_fn bb_version_p, bb_last_error_p;
static int_fn bb_init_p, bb_start_p, bb_stop_p, bb_channel_count_p;
static str_int_fn bb_load_p, bb_bus_open_p;
static idx_str_fn bb_channel_name_p, bb_channel_iface_p;
static send_fn bb_bus_send_p;
static recv_fn bb_bus_recv_p;
static int_int_fn bb_bus_health_p, bb_bus_close_p, bb_channel_kind_p, bb_channel_health_source_p, bb_wait_released_p;

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

/* the row's message called `name`, by its index; -1 when there is none */
static int message_named(int row, const char *name) {
	char buf[256];
	int n = bb_message_count_p(row);
	for (int m = 0; m < n; m++) {
		int len = bb_message_name_p(row, m, buf, sizeof buf);
		if (len >= 0 && len < (int)sizeof buf && strcmp(buf, name) == 0) return m;
	}
	return -1;
}

static int signal_named(int row, int m, const char *name) {
	char buf[256];
	bb_message mi;
	if (bb_message_info_p(row, m, &mi) != 0) return -1;
	for (int s = 0; s < mi.signals; s++) {
		int len = bb_signal_name_p(row, m, s, buf, sizeof buf);
		if (len >= 0 && len < (int)sizeof buf && strcmp(buf, name) == 0) return s;
	}
	return -1;
}

#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL " __VA_ARGS__); fprintf(stderr, " (%s)\n", bb_last_error_p()); return 1; } } while (0)

/* CAN1's database, dbc/blobly_net.dbc: Powertrain is 0x100, 8 bytes, EngineSpeed 0|16 at 0.25 rpm,
 * Gear 43|4 with a value table (3 "Third") */
static int dbc_steps(int row) {
	int pt = message_named(row, "Powertrain");
	CHECK(pt >= 0, "no Powertrain in CAN1's database");
	bb_message mi;
	CHECK(bb_message_info_p(row, pt, &mi) == 0 && mi.id == 0x100 && !mi.ext && mi.dlc == 8 && mi.signals == 6 && !mi.j1939,
		"Powertrain's info: id 0x%X dlc %d signals %d", mi.id, mi.dlc, mi.signals);
	char cut[4];
	CHECK(bb_message_name_p(row, pt, cut, sizeof cut) == 10 && strcmp(cut, "Pow") == 0, "a cut name answers its whole length");
	CHECK(bb_message_name_p(row, pt, NULL, 0) == 10, "cap 0 asks for the length alone");
	int es = signal_named(row, pt, "EngineSpeed"), gear = signal_named(row, pt, "Gear");
	CHECK(es >= 0 && gear >= 0, "Powertrain's signals");
	bb_signal si;
	char unit[16];
	CHECK(bb_signal_info_p(row, pt, es, &si) == 0 && si.start_bit == 0 && si.length == 16 && si.factor == 0.25
		&& !si.big_endian && !si.is_signed && si.labels == 0 && si.maximum == 16383.75, "EngineSpeed's info");
	CHECK(bb_signal_unit_p(row, pt, es, unit, sizeof unit) == 3 && strcmp(unit, "rpm") == 0, "EngineSpeed's unit: %s", unit);
	CHECK(bb_signal_info_p(row, pt, gear, &si) == 0 && si.labels == 7, "Gear's value table: %d labels", si.labels);
	char label[32];
	double value = -1;
	uint64_t raw = 99;
	CHECK(bb_signal_label_p(row, pt, gear, 3, &raw, &value, label, sizeof label) == 5 && strcmp(label, "Third") == 0
		&& raw == 3 && value == 3, "Gear's label 3: %s = %g", label, value);
	CHECK(bb_signal_label_p(row, pt, gear, 3, NULL, NULL, NULL, 0) == 5, "a label's length alone");
	CHECK(bb_signal_label_p(row, pt, gear, 7, &raw, &value, label, sizeof label) == BB_ERR, "a label past the table must refuse");

	/* encode as bus.send_message does: the named signals set, every other at raw 0 */
	const char *names[] = {"EngineSpeed", "Gear"};
	const double values[] = {1500, 3};
	bb_frame f;
	memset(&f, 0xAA, sizeof f);
	CHECK(bb_encode_p(row, pt, 2, names, values, &f) == 0, "encode");
	const uint8_t want[8] = {0x70, 0x17, 0, 0, 0, 0x18, 0, 0}; /* 1500 / 0.25 = 0x1770; 3 << 43 */
	CHECK(f.id == 0x100 && f.len == 8 && !f.ext && !f.fd && !f.brs && memcmp(f.data, want, 8) == 0 && f.data[8] == 0,
		"Powertrain encoded as %02X %02X .. %02X", f.data[0], f.data[1], f.data[5]);
	const char *bad[] = {"Nope"};
	CHECK(bb_encode_p(row, pt, 1, bad, values, &f) == BB_ERR && strstr(bb_last_error_p(), "unknown signal \"Nope\" in Powertrain"),
		"an unknown signal must refuse by name");

	/* decode it back: the message, each signal's physical value, every one carried */
	bb_encode_p(row, pt, 2, names, values, &f);
	int m = -1;
	double got[16];
	uint8_t on[16];
	CHECK(bb_decode_p(row, &f, &m, got, on, 16) == 0 && m == pt && got[es] == 1500 && got[gear] == 3 && on[es] && on[gear],
		"decode: message %d, EngineSpeed %g, Gear %g", m, got[es], got[gear]);
	m = -1;
	CHECK(bb_decode_p(row, &f, &m, got, on, 2) == BB_ERR && m == pt, "arrays too short must refuse, naming the message");
	bb_frame other = {.id = 0x7FF, .len = 1};
	CHECK(bb_decode_p(row, &other, &m, got, on, 16) == BB_NONE, "a frame of no message is BB_NONE");
	bb_frame remote = {.id = 0x100, .len = 8, .rtr = 1};
	CHECK(bb_decode_p(row, &remote, &m, got, on, 16) == BB_NONE, "a remote frame carries nothing to decode");

	/* what the simulated SUT sends decodes too */
	int h = bb_bus_open_p("inproc:CAN1");
	CHECK(h >= 0, "open for decode");
	int decoded = 0;
	for (int i = 0; i < 20 && !decoded; i++) {
		CHECK(bb_bus_recv_p(h, 1000, &f) == 0, "recv for decode");
		decoded = bb_decode_p(row, &f, &m, got, on, 16) == 0;
	}
	bb_bus_close_p(h);
	CHECK(decoded, "nothing the simulation sent decoded");
	printf("ok   CAN1's database: Powertrain listed, encoded, decoded; a frame the simulation sent decoded\n");
	return 0;
}

/* faults on CAN1's simulated ECUs, refused by name where they could not take effect, and E2E
 * Profile 1 on blobly_emb overspeed's BrakeStatus layout (blobly/sim/e2e_p01_test.v's vectors) */
static int fault_steps(int row, int doip) {
	CHECK(bb_sim_fault_p(doip, "SUT", "Powertrain", "drop", 0, NULL) == BB_ERR && strstr(bb_last_error_p(), "DoIP channel"),
		"a fault on a DoIP row must refuse by name");
	CHECK(bb_sim_fault_p(row, "SUT", "Powertrain", "bad_crc", 0, NULL) == BB_ERR && strstr(bb_last_error_p(), "no configured checksum"),
		"bad_crc where nothing is protected must refuse");
	CHECK(bb_sim_fault_p(row, "SUT", "Powertrain", "drop", 500, NULL) == 0, "drop Powertrain");
	CHECK(bb_sim_fault_p(row, "SUT", "Powertrain", "clear", 0, "") == 0 && bb_sim_clear_faults_p() == 0, "clear");
	uint8_t f[6] = {0xE8, 0x03, 0x5A, 0x00, 0x00, 0x03};
	CHECK(bb_e2e_p01_crc_p(f, 6, 0x1244, 4, 5, NULL) == 0xCF && bb_e2e_p01_crc_p(f, 6, 0x1244, 4, 5, "alt") == 0x78,
		"the Profile 1 CRC of counter 3");
	f[5] = 0xA0;
	CHECK(bb_e2e_p01_protect_p(f, 6, 0x1244, 4, 5, 3, "") == 0 && f[5] == 0xA3 && f[4] == bb_e2e_p01_crc_p(f, 6, 0x1244, 4, 5, ""),
		"protect writes the counter's nibble and stamps the CRC");
	CHECK(bb_e2e_p01_protect_p(f, 6, 0x1244, 4, 5, 15, "") == BB_ERR && strstr(bb_last_error_p(), "0..14"), "counter 15 must refuse");
	printf("ok   faults armed and refused by name; E2E Profile 1 is the reference\n");
	return 0;
}

static int can1_row = -1; /* CAN1's row, for the host thread's database read */

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
	if (!rc && bb_message_count_p(can1_row) <= 0) { fprintf(stderr, "FAIL a database read on the host thread: %s\n", bb_last_error_p()); rc = 1; }
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
	SYM(bb_channel_kind); SYM(bb_channel_health_source); SYM(bb_wait_released);
	SYM(bb_message_count); SYM(bb_message_info); SYM(bb_message_name); SYM(bb_signal_info);
	SYM(bb_signal_name); SYM(bb_signal_unit); SYM(bb_signal_label); SYM(bb_encode); SYM(bb_decode);
	SYM(bb_sim_fault); SYM(bb_sim_clear_faults); SYM(bb_e2e_p01_crc); SYM(bb_e2e_p01_protect);

	if (bb_init_p() != 0) FAIL("init");
	if (bb_thread_attach_p() != 0) FAIL("attach on the loading thread must be harmless");
	printf("libblobly %s\n", bb_version_p());
	if (bb_start_p() != BB_ERR_STATE) { fprintf(stderr, "FAIL start before load must refuse\n"); return 1; }
	/* an error longer than BB_ERROR_MAX is cut before a whole character: a path of 3000 two-byte
	 * characters makes one of ~6000 bytes */
	{
		static char longpath[3000 * 2 + 1];
		for (int i = 0; i < 3000; i++) { longpath[2 * i] = (char)0xC3; longpath[2 * i + 1] = (char)0xA9; }
		if (bb_load_p(longpath) != BB_ERR) { fprintf(stderr, "FAIL a missing project must refuse\n"); return 1; }
		const char *e = bb_last_error_p();
		size_t el = strlen(e);
		if (el == 0 || el > BB_ERROR_MAX) { fprintf(stderr, "FAIL error length %zu\n", el); return 1; }
		/* the last character is whole: count the trailing continuation bytes behind its lead */
		size_t k = el;
		while (k > 0 && ((unsigned char)e[k - 1] & 0xC0) == 0x80) k--;
		unsigned char lead = k > 0 ? (unsigned char)e[k - 1] : 0;
		size_t want = (lead & 0xE0) == 0xC0 ? 1 : (lead & 0xF0) == 0xE0 ? 2 : (lead & 0xF8) == 0xF0 ? 3 : 0;
		if (el - k != want) { fprintf(stderr, "FAIL the error was cut inside a UTF-8 character\n"); return 1; }
		printf("ok   a %zu-byte error, cut at a character boundary\n", el);
	}
	if (bb_load_p(argv[2]) != 0) FAIL("load");
	int n = bb_channel_count_p();
	if (n < 2) { fprintf(stderr, "FAIL channels: %d\n", n); return 1; }
	int doip = -1, can1 = -1;
	static char doip_iface[256];
	for (int i = 0; i < n; i++) {
		int kind = bb_channel_kind_p(i), src = bb_channel_health_source_p(i);
		if (strcmp(bb_channel_name_p(i), "CAN1") == 0) can1 = i;
		printf("     channel %s (%s) kind %d health source %d\n", bb_channel_name_p(i), bb_channel_iface_p(i), kind, src);
		if (kind < 0 || src < 0) FAIL("channel kind / health source");
		if (kind == BB_KIND_DOIP) { doip = i; snprintf(doip_iface, sizeof doip_iface, "%s", bb_channel_iface_p(i)); }
		/* sim-demo's CAN rows are inproc: a software bus has no ladder */
		if (kind == BB_KIND_CAN && strncmp(bb_channel_iface_p(i), "inproc:", 7) == 0 && src != BB_HEALTH_SOURCE_NONE) { fprintf(stderr, "FAIL inproc health source %d\n", src); return 1; }
	}
	if (doip < 0 || can1 < 0) { fprintf(stderr, "FAIL sim-demo has a DoIP row and a CAN1\n"); return 1; }
	if (bb_message_count_p(can1) != BB_ERR_STATE) { fprintf(stderr, "FAIL a row's databases are the run's: none before start\n"); return 1; }
	if (bb_channel_kind_p(n) != BB_ERR) { fprintf(stderr, "FAIL kind of a row past the end\n"); return 1; }
	/* a DoIP endpoint is not a CAN bus: refused by name, not as a missing SocketCAN device */
	if (bb_bus_open_p(doip_iface) != BB_ERR || strstr(bb_last_error_p(), "DoIP or SOME/IP") == NULL) { fprintf(stderr, "FAIL open of a DoIP row: %s\n", bb_last_error_p()); return 1; }
	printf("ok   kinds and health sources; a DoIP row refused by name\n");
	if (bb_sim_fault_p(can1, "SUT", "Powertrain", "drop", 0, NULL) != BB_ERR_STATE) { fprintf(stderr, "FAIL a fault before start must refuse\n"); return 1; }
	if (bb_start_p() != 0) FAIL("start");
	if (bb_start_p() != BB_ERR_STATE) { fprintf(stderr, "FAIL a second start must refuse\n"); return 1; }

	if (exchange("main thread", 20)) return 1;
	if (dbc_steps(can1)) return 1;
	if (fault_steps(can1, doip)) return 1;
	can1_row = can1;
	if (bb_message_count_p(n) != BB_ERR) { fprintf(stderr, "FAIL the databases of a row past the end\n"); return 1; }
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
	/* the run moved the hosted DoIP entity onto a port it could bind; a stop gives the project's back */
	if (strcmp(bb_channel_iface_p(doip), doip_iface) == 0) { fprintf(stderr, "FAIL the run did not move %s\n", doip_iface); return 1; }
	if (bb_stop_p() != 0) FAIL("stop");
	if (bb_message_count_p(can1) != BB_ERR_STATE) { fprintf(stderr, "FAIL the databases outlived the run\n"); return 1; }
	if (strcmp(bb_channel_iface_p(doip), doip_iface) != 0) { fprintf(stderr, "FAIL after stop the DoIP row is %s, not %s\n", bb_channel_iface_p(doip), doip_iface); return 1; }
	if (bb_wait_released_p(0) != 0) { fprintf(stderr, "FAIL a clean stop must leave the process released\n"); return 1; }
	printf("ok   stop restores the project's interfaces; released at once\n");
	if (bb_stop_p() != BB_ERR_STATE) { fprintf(stderr, "FAIL a second stop must refuse\n"); return 1; }
	/* the process is free again: the same project starts a second time */
	if (bb_start_p() != 0) FAIL("start again");
	if (exchange("second run", 5)) return 1;
	if (bb_stop_p() != 0) FAIL("stop again");
	printf("ok   libblobly smoke\n");
	return 0;
}
