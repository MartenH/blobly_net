/* smoke.c — a C host of libblobly: loads the library at run time, brings sim-demo up, hears
 * its simulated ECUs on inproc:CAN1, sends a frame, and does the same from a thread the HOST
 * created — the one the V runtime's collector did not see born — encodes and decodes through
 * CAN1's database (dbc/blobly_net.dbc), reads a DID of CAN1's SUT over UDS, arms and clears a
 * fault and stamps an E2E Profile 1 frame, flashes a simulated bootloader on CAN1 with C
 * callbacks, fires and cycles a generator, then stops and starts again.
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
typedef int64_t (*i64_fn)(void);
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
typedef int (*uds_open_fn)(int, const int64_t *, const int64_t *, bb_uds_target *);
typedef int (*uds_did_fn)(int, int, uint8_t *, int);
typedef int (*uds_last_fn)(int, bb_uds_exchange *, uint8_t *, int, uint8_t *, int);
typedef int (*uds_data_fn)(int, uint8_t *, int);
typedef int (*uds_dtc_fn)(int, int, bb_dtc *);
typedef int (*dtc_name_fn)(int, char *, int);
static int_int_fn bb_uds_supported_dtcs_p;
static uds_dtc_fn bb_uds_dtc_p;
static dtc_name_fn bb_dtc_name_p;
static uds_open_fn bb_uds_open_p;
static uds_did_fn bb_uds_read_did_p;
static uds_last_fn bb_uds_last_p;
static uds_data_fn bb_uds_data_p;
typedef int (*doip_discover_fn)(const char *, int, int, bb_doip_announcement *);
typedef int (*doip_endpoint_fn)(int, char *, int, int *);
static doip_discover_fn bb_doip_discover_p;
static doip_endpoint_fn bb_doip_endpoint_p;
typedef int (*last_nrc_fn)(uint8_t *);
static last_nrc_fn bb_last_nrc_p;
typedef int (*fault_fn)(int, const char *, const char *, const char *, int, const char *);
typedef int (*p01_crc_fn)(const uint8_t *, int, int, int, int, const char *);
typedef int (*p01_protect_fn)(uint8_t *, int, int, int, int, int, const char *);
static fault_fn bb_sim_fault_p;
static int_fn bb_sim_clear_faults_p;
static p01_crc_fn bb_e2e_p01_crc_p;
static p01_protect_fn bb_e2e_p01_protect_p;
typedef int (*e2e_attach_fn)(int, int);
typedef int (*e2e_stamp_fn)(int, int, bb_frame *);
static e2e_attach_fn bb_e2e_attach_p;
static e2e_stamp_fn bb_e2e_stamp_p;
static int_fn bb_thread_attach_p, bb_thread_detach_p;
typedef int (*flash_defaults_fn)(bb_flash_opts *);
typedef int (*flash_program_fn)(int, const uint8_t *, int, const bb_flash_opts *, bb_flash_report *);
typedef int (*boot_sim_fn)(int, const int64_t *, const int64_t *);
typedef int (*boot_stop_fn)(int, bb_boot_report *);
static flash_defaults_fn bb_flash_defaults_p;
static uds_open_fn bb_flash_open_p;
static flash_program_fn bb_flash_program_p;
static boot_sim_fn bb_boot_sim_p;
static boot_stop_fn bb_boot_sim_stop_p;
typedef int (*gen_find_fn)(const char *);
typedef int (*gen_info_fn)(int, bb_generator *);
typedef int (*gen_text_fn)(int, int, char *, int);
typedef int (*gen_cycle_fn)(int, int);
typedef int (*gen_set_fn)(int, const char *, double);
typedef int (*gen_source_fn)(int, const char *, const bb_wave *);
static gen_find_fn bb_gen_find_p;
static gen_info_fn bb_gen_info_p;
static gen_text_fn bb_gen_text_p;
static gen_cycle_fn bb_gen_start_p, bb_gen_cycle_p;
static gen_set_fn bb_gen_set_p;
static gen_source_fn bb_gen_source_p;
static int (*bb_gen_fire_p)(int, int64_t, int64_t);
static int (*bb_gen_stop_p)(int);
static int (*bb_gen_count_p)(void);
static int (*bb_gen_run_p)(int64_t *);
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
static i64_fn bb_now_ns_p;
static int_int_fn bb_bus_health_p, bb_bus_close_p, bb_channel_kind_p, bb_channel_health_source_p, bb_wait_released_p,
	bb_uds_close_p;

typedef int (*load_fn)(int, bb_busload *);
typedef int (*diag_fn)(int, bb_diagnostics *);
static load_fn bb_bus_load_p;
static diag_fn bb_bus_diagnostics_p;

#define FAIL(step) do { fprintf(stderr, "FAIL %s: %s\n", step, bb_last_error_p()); return 1; } while (0)

/* hear n frames and send one, on a handle of this thread's own */
static int exchange(const char *who, int n) {
	int h = bb_bus_open_p("inproc:CAN1");
	if (h < 0) { fprintf(stderr, "FAIL %s open: %s\n", who, bb_last_error_p()); return 1; }
	bb_frame f;
	for (int i = 0; i < n; i++) {
		int64_t before = bb_now_ns_p();
		int rc = bb_bus_recv_p(h, 1000, &f);
		if (rc != 0) { fprintf(stderr, "FAIL %s recv %d: rc=%d %s\n", who, i, rc, bb_last_error_p()); return 1; }
		/* a software bus has no stamp: the frame carries its receipt, inside the call */
		if (f.t_ns < before || f.t_ns > bb_now_ns_p()) { fprintf(stderr, "FAIL %s recv %d: t_ns outside the call\n", who, i); return 1; }
	}
	memset(&f, 0, sizeof f);
	f.id = 0x123; f.len = 3; f.data[0] = 1; f.data[1] = 2; f.data[2] = 3;
	if (bb_bus_send_p(h, &f) != 0) { fprintf(stderr, "FAIL %s send: %s\n", who, bb_last_error_p()); return 1; }
	if (bb_bus_health_p(h) != BB_HEALTH_UNKNOWN) { fprintf(stderr, "FAIL %s health: a software bus has no ladder\n", who); return 1; }
	bb_busload load;
	bb_diagnostics diag;
	if (bb_bus_load_p(h, &load) != 0 || load.frames != (uint64_t)n + 1) { fprintf(stderr, "FAIL %s load: %s\n", who, bb_last_error_p()); return 1; }
	if (bb_bus_diagnostics_p(h, &diag) != 0) { fprintf(stderr, "FAIL %s diagnostics: %s\n", who, bb_last_error_p()); return 1; }
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
	/* sim-demo declares no E2E: a stamp leaves the frame as encoded, and a short one is refused */
	bb_encode_p(row, pt, 2, names, values, &f);
	CHECK(bb_e2e_stamp_p(row, pt, &f) == BB_NONE && memcmp(f.data, want, 8) == 0, "Powertrain declares no E2E to stamp");
	f.len = 4;
	CHECK(bb_e2e_stamp_p(row, pt, &f) == BB_ERR && strstr(bb_last_error_p(), "shorter than Powertrain"), "a short frame must refuse");

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
	CHECK(bb_e2e_attach_p(h, row) == 0, "sim-demo's CAN1 has no message with E2E to judge");
	int decoded = 0;
	for (int i = 0; i < 20 && !decoded; i++) {
		CHECK(bb_bus_recv_p(h, 1000, &f) == 0 && f.e2e == BB_E2E_NONE, "recv for decode");
		decoded = bb_decode_p(row, &f, &m, got, on, 16) == 0;
	}
	bb_bus_close_p(h);
	CHECK(decoded, "nothing the simulation sent decoded");
	printf("ok   CAN1's database: Powertrain listed, encoded, decoded; a frame the simulation sent decoded\n");
	return 0;
}

/* UDS on CAN1: sim-demo's SUT answers 0x7E0 / 0x7E8, its VIN 17 bytes (a multi-frame answer) */
static int uds_steps(int row) {
	bb_uds_target t;
	int64_t bad = -2;
	CHECK(bb_uds_open_p(row, &bad, NULL, &t) == BB_ERR && strstr(bb_last_error_p(), "not a CAN identifier"), "tx -2 must refuse");
	int u = bb_uds_open_p(row, NULL, NULL, &t);
	CHECK(u >= 0 && t.tx == 0x7E0 && t.rx == 0x7E8 && !t.ext, "open on the default ids");
	uint8_t cut[4], vin[32];
	CHECK(bb_uds_read_did_p(u, 0xF190, cut, sizeof cut) == 17 && memcmp(cut, "BLOB", 4) == 0, "a VIN cut at the buffer answers its whole length");
	CHECK(bb_uds_data_p(u, vin, sizeof vin) == 17 && memcmp(vin, "BLOBLYNETV0SUT001", 17) == 0, "bb_uds_data copies it again, whole");
	CHECK(bb_uds_read_did_p(u, 0xABCD, vin, sizeof vin) == BB_ERR_NEGATIVE, "an unknown DID is a negative response");
	uint8_t nrc = 0;
	CHECK(bb_last_nrc_p(&nrc) == 0 && nrc == 0x31, "the thread's last NRC is 0x31");
	CHECK(bb_uds_data_p(u, vin, sizeof vin) == 0, "a failed call holds no bytes of an earlier one");
	bb_uds_exchange x;
	uint8_t req[8], ans[8];
	CHECK(bb_uds_last_p(u, &x, req, sizeof req, ans, sizeof ans) == 0 && x.negative && x.nrc == 0x31 && x.sent
		&& x.request_len == 3 && x.answer_len == 3 && ans[0] == 0x7F && req[0] == 0x22, "the last exchange names NRC 0x31");
	CHECK(bb_uds_read_did_p(u, 0x10000, vin, sizeof vin) == BB_ERR, "a DID past 16 bits must refuse");
	/* a buffer bb.h does not allow is refused BEFORE the request goes out */
	CHECK(bb_uds_read_did_p(u, 0xF190, NULL, 4) == BB_ERR, "a NULL buffer of 4 bytes must refuse");
	CHECK(bb_uds_last_p(u, &x, req, sizeof req, ans, sizeof ans) == 0 && x.nrc == 0x31, "a refused call sent nothing");
	/* the fault memory as a model: SUT's two DTCs, the first P1234-56, confirmed and failing */
	bb_dtc d;
	char name[16];
	CHECK(bb_uds_supported_dtcs_p(u) == 2 && bb_uds_dtc_p(u, 0, &d) == 0 && d.code == 0x123456 && d.status == 0x09,
		"0x19 0A: two DTCs, the first 0x123456 status 0x09");
	CHECK(bb_dtc_name_p((int)d.code, name, sizeof name) == 8 && strcmp(name, "P1234-56") == 0, "its display name: %s", name);
	CHECK(bb_uds_dtc_p(u, 2, &d) == BB_ERR, "a DTC past the answer must refuse");
	CHECK(bb_uds_close_p(u) == 0 && bb_uds_close_p(u) == BB_ERR_HANDLE, "a closed UDS handle is gone");
	printf("ok   UDS on CAN1: the VIN read, a negative response typed with its NRC, the DTCs\n");
	return 0;
}

/* UDS over sim-demo's DoIP1, from tester 0x0E80 to its entity at 0x1000, and the entity asked who
 * it is */
static int doip_steps(int doip) {
	bb_uds_target t;
	int64_t id = 0x7E0;
	CHECK(bb_uds_open_p(doip, &id, NULL, &t) == BB_ERR && strstr(bb_last_error_p(), "DoIP addressing"), "CAN ids on a DoIP row must refuse");
	int u = bb_uds_open_p(doip, NULL, NULL, &t);
	CHECK(u >= 0 && t.tx == 0x0E80 && t.rx == 0x1000, "open on the row's logical addresses");
	CHECK(bb_uds_open_p(doip, NULL, NULL, &t) == BB_ERR, "a second handle on the row's connection must refuse");
	uint8_t vin[32];
	CHECK(bb_uds_read_did_p(u, 0xF190, vin, sizeof vin) == 17 && memcmp(vin, "BLOBLYNETV0SUT001", 17) == 0, "the VIN over DoIP");
	CHECK(bb_uds_close_p(u) == 0, "close the DoIP handle");
	bb_doip_announcement a;
	char host[64];
	int port = 0;
	CHECK(bb_doip_endpoint_p(doip, host, sizeof host, &port) > 0 && port > 0, "the run's DoIP1 endpoint");
	CHECK(bb_doip_discover_p(host, port, 1200, &a) == 0 && strcmp(a.vin, "BLOBLYNETV0SUT001") == 0 && a.logical_address == 0x1000,
		"discover: %s 0x%04X", a.vin, a.logical_address);
	printf("ok   UDS over DoIP1: the VIN read; discovered %s at 0x%04X from %s\n", a.vin, a.logical_address, a.source);
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

/* sim-demo's generators: a manual one fired with a value set, its cycle started and stopped, a
 * cyclic one's cycle changed, and the refusals typed */
static int gen_steps(void) {
	CHECK(bb_gen_count_p() == 4, "sim-demo writes four generators");
	int hb = bb_gen_find_p("CAN1/Heartbeat pulse");
	CHECK(hb >= 0, "find a generator by channel and name");
	char msg[32];
	CHECK(bb_gen_text_p(hb, BB_GEN_MESSAGE, msg, sizeof msg) == 9 && strcmp(msg, "Heartbeat") == 0, "its message");
	CHECK(bb_gen_set_p(hb, "Counter", 42) == 0 && bb_gen_fire_p(hb, 0, 0) == 0, "set and fire");
	int64_t run;
	CHECK(bb_gen_run_p(&run) == 0 && bb_gen_fire_p(hb, run, 0) == 0 && bb_gen_fire_p(hb, run + 1, 0) == BB_ERR_STATE,
		"a fire names its run, and another run's is refused");
	bb_wave w = {.kind = "counter", .step = 1, .modulo = 256};
	CHECK(bb_gen_source_p(hb, "Counter", &w) == 0 && bb_gen_start_p(hb, 20) == 0, "a source, then a cycle");
	bb_generator g;
	CHECK(bb_gen_info_p(hb, &g) == 0 && g.running && g.cycle_ms == 20 && g.id == 0x700 && g.sent >= 1, "its state");
	CHECK(bb_gen_stop_p(hb) == 0 && bb_gen_info_p(hb, &g) == 0 && !g.running, "stop");
	int wake = bb_gen_find_p("Cyclic wake (0x123)");
	CHECK(wake >= 0 && bb_gen_cycle_p(wake, 250) == 0, "a cyclic generator's cycle");
	CHECK(bb_gen_cycle_p(wake, 0) == BB_ERR && strstr(bb_last_error_p(), "a cycle is 1"), "cycle 0 must refuse");
	CHECK(bb_gen_set_p(wake, "Counter", 1) == BB_ERR && strstr(bb_last_error_p(), "raw frame"), "a raw frame has no signals");
	CHECK(bb_gen_find_p("nope") == BB_ERR, "an unknown generator must refuse");
	printf("ok   generators fired, cycled and refused by name\n");
	return 0;
}

/* a flash of a simulated bootloader on CAN1, its milestones and progress through C callbacks */
static int notes, progress_calls, last_done;
static void on_note(void *ctx, const char *line) { (void)ctx; (void)line; notes++; }
static void on_progress(void *ctx, int32_t done, int32_t total) { (void)ctx; (void)total; progress_calls++; last_done = done; }
static int flash_steps(int row) {
	int sim = bb_boot_sim_p(row, NULL, NULL);
	CHECK(sim >= 0, "boot sim");
	bb_uds_target t;
	int u = bb_flash_open_p(row, NULL, NULL, &t);
	CHECK(u >= 0 && t.tx == 0x7B0 && t.rx == 0x7B8, "flash open on the bootloader's ids");
	bb_flash_opts o;
	CHECK(bb_flash_defaults_p(&o) == 0 && o.base == 0x08020000 && o.auth == 1, "flash defaults");
	o.note = on_note;
	o.progress = on_progress;
	static uint8_t image[3000];
	bb_flash_report r;
	CHECK(bb_flash_program_p(u, image, sizeof image, &o, &r) == 0 && r.auth == BB_FLASH_AUTHENTICATED && r.reset_acknowledged,
		"flash");
	CHECK(notes > 3 && progress_calls > 0 && last_done == r.blocks, "the callbacks: %d notes, %d progress", notes, progress_calls);
	bb_boot_report b;
	CHECK(bb_uds_close_p(u) == 0 && bb_boot_sim_stop_p(sim, &b) == 0 && b.verified && b.bytes == r.bytes, "boot sim report");
	printf("ok   flashed %d bytes in %d blocks; %d notes, %d progress calls\n", r.bytes, r.blocks, notes, progress_calls);
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
	SYM(bb_bus_open); SYM(bb_bus_send); SYM(bb_bus_recv); SYM(bb_now_ns); SYM(bb_bus_health); SYM(bb_bus_close);
	SYM(bb_bus_load); SYM(bb_bus_diagnostics);
	SYM(bb_channel_kind); SYM(bb_channel_health_source); SYM(bb_wait_released);
	SYM(bb_message_count); SYM(bb_message_info); SYM(bb_message_name); SYM(bb_signal_info);
	SYM(bb_signal_name); SYM(bb_signal_unit); SYM(bb_signal_label); SYM(bb_encode); SYM(bb_decode);
	SYM(bb_uds_open); SYM(bb_uds_read_did); SYM(bb_uds_last); SYM(bb_uds_data); SYM(bb_uds_close); SYM(bb_last_nrc);
	SYM(bb_sim_fault); SYM(bb_sim_clear_faults); SYM(bb_e2e_p01_crc); SYM(bb_e2e_p01_protect);
	SYM(bb_e2e_attach); SYM(bb_e2e_stamp);
	SYM(bb_uds_supported_dtcs); SYM(bb_uds_dtc); SYM(bb_dtc_name); SYM(bb_doip_discover); SYM(bb_doip_endpoint);
	SYM(bb_flash_defaults); SYM(bb_flash_open); SYM(bb_flash_program); SYM(bb_boot_sim); SYM(bb_boot_sim_stop);
	SYM(bb_gen_count); SYM(bb_gen_run); SYM(bb_gen_find); SYM(bb_gen_info); SYM(bb_gen_text); SYM(bb_gen_fire); SYM(bb_gen_start);
	SYM(bb_gen_stop); SYM(bb_gen_cycle); SYM(bb_gen_set); SYM(bb_gen_source);

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
	/* a UDS connection opens on the run's rows: before start no listen-only mark is published */
	if (bb_uds_open_p(can1, NULL, NULL, NULL) != BB_ERR_STATE) { fprintf(stderr, "FAIL a UDS open before start must refuse\n"); return 1; }
	if (bb_sim_fault_p(can1, "SUT", "Powertrain", "drop", 0, NULL) != BB_ERR_STATE) { fprintf(stderr, "FAIL a fault before start must refuse\n"); return 1; }
	if (bb_start_p() != 0) FAIL("start");
	if (bb_start_p() != BB_ERR_STATE) { fprintf(stderr, "FAIL a second start must refuse\n"); return 1; }

	if (exchange("main thread", 20)) return 1;
	if (dbc_steps(can1)) return 1;
	if (uds_steps(can1)) return 1;
	if (doip_steps(doip)) return 1;
	if (fault_steps(can1, doip)) return 1;
	if (flash_steps(can1)) return 1;
	if (gen_steps()) return 1;
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
