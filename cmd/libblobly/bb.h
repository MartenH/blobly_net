/* bb.h — the C ABI of libblobly, the Blobly Net engine as a shared library (cmd/libblobly).
 *
 * THE ONE STATEMENT OF THE ABI: V compiles this header in (cmd/libblobly/lib.v) and every host
 * — the C smoke, the ctypes smoke, a Python package — reads it. What the two sides disagree on
 * is a crash, so nothing about a call lives anywhere else.
 *
 * Conventions:
 *   - every call returns int: 0 on success, < 0 on error, and bb_last_error() names the last
 *     error (the message belongs to the library; copy it if you keep it; at most BB_ERROR_MAX
 *     bytes, a longer one cut before a whole UTF-8 character). Calls that have a non-error
 *     answer that is not plain success return > 0 for it, one of the BB_* answers below.
 *     bb_bus_open, bb_uds_open, bb_bus_health and the bb_channel_* enums return their value
 *     when >= 0.
 *   - LOAD THE LIBRARY FROM THE PROCESS'S MAIN THREAD, and call bb_init() once before anything
 *     else. The V runtime initialises itself when the library is loaded (a constructor) and takes
 *     the loading thread for the main one — loaded from a worker, its collector scans the wrong
 *     stack and the real main thread is unknown to it; nothing inside can detect or repair that.
 *     bb_init is where a host-side requirement would go, and a host that calls it is not broken
 *     by one.
 *   - a thread the HOST created calls bb_thread_attach() before its first other call and
 *     bb_thread_detach() before it ends: the library's collector scans the stacks of the threads
 *     it knows, and an allocation on an unknown one aborts the process at the next collection
 *     ("Collecting from unknown thread"). The loading thread needs neither: attaching it is
 *     harmless, and detaching a thread attach did not register is refused.
 *   - bb_last_error is PER THREAD: the calling thread's last error, "" after its last success.
 *   - ONE HOST THREAD drives the library's STATE in this version: open, close, load, start and
 *     stop are not synchronised against each other.
 *   - ONE THREAD USES A BUS HANDLE: its send, recv and health calls come from one thread at a
 *     time — which may be an attached thread of its own, not the driver's. The backends are not
 *     safe for more (Kvaser's canlib forbids two threads on one handle; SocketCAN's ladder state
 *     is written by recv and read by health), so open a handle per thread instead. The one
 *     call that may come from ANOTHER thread is bb_bus_close, which ends a recv in progress.
 *   - A frame received is copied into the caller's bb_frame; nothing handed out points into the
 *     library except the strings: bb_channel_name / bb_channel_iface's stay valid until the next
 *     bb_load, bb_start or bb_stop, bb_last_error's until the calling thread's next call. A
 *     database's strings are copied into the caller's buffer instead (see "A row's databases").
 *   - the engine's progress and warnings go to the process's stdout and stderr, as the headless
 *     runner's do.
 */
#ifndef BLOBLY_BB_H
#define BLOBLY_BB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A CAN frame on the wire. `len` is the payload length (0..8 classic, up to 64 with fd); `ext`
 * a 29-bit identifier; `fd`/`brs` CAN-FD and its bit-rate switch; `rtr` a remote frame (its
 * `len` the requested DLC, no payload); `esi` CAN-FD's error-state indicator. On a send, fd and
 * brs unset mean "not stated": the frame takes the wire's declared format; a frame no controller
 * could send (brs or esi without fd, an id past its width) and a remote frame are refused by the
 * transport, as for every sender in this app. A received frame that does not fit is refused, not
 * truncated. */
typedef struct bb_frame {
	uint32_t id;
	uint8_t  len;
	uint8_t  ext;
	uint8_t  fd;
	uint8_t  brs;
	uint8_t  rtr;
	uint8_t  esi;
	uint8_t  data[64];
} bb_frame;

/* The controller's fault ladder (transport.BusHealth), as bb_bus_health returns it. */
enum bb_health {
	BB_HEALTH_UNKNOWN = 0,  /* the backend cannot say: a software bus, or no status seen yet */
	BB_HEALTH_OK = 1,
	BB_HEALTH_WARNING = 2,
	BB_HEALTH_ERROR_PASSIVE = 3,
	BB_HEALTH_BUS_OFF = 4
};

/* What a row of the project is (bb_channel_kind): only a CAN row is something bb_bus_open opens. */
enum bb_kind {
	BB_KIND_CAN = 0,
	BB_KIND_DOIP = 1,    /* diagnostics over Ethernet: no frames */
	BB_KIND_SOMEIP = 2   /* a SOME/IP listener endpoint: no frames */
};

/* Where a CAN row's ladder comes from (bb_channel_health_source, transport.health_source). */
enum bb_health_source {
	BB_HEALTH_SOURCE_NONE = 0,          /* no controller (a software bus, a non-CAN row): no ladder */
	BB_HEALTH_SOURCE_POLLED = 1,        /* the driver is asked: health answers without a reader */
	BB_HEALTH_SOURCE_NEEDS_READER = 2   /* the ladder moves only while a handle on the wire is read
	                                       (SocketCAN, Vector): health on a handle nobody reads stays
	                                       where it was */
};

/* A message of a row's databases (bb_message_info). Its name is bb_message_name's. */
typedef struct bb_message {
	uint32_t id;
	uint8_t  ext;      /* a 29-bit identifier */
	uint8_t  j1939;    /* the database declares it J1939 (VFrameFormat J1939PG) */
	int32_t  dlc;      /* the payload length bb_encode gives it: the DBC's DLC, 0 for a negative
	                      one (one past 64 bb_encode refuses) */
	int32_t  signals;  /* how many signals it has: bb_signal_info's s is 0 .. signals - 1 */
} bb_message;

/* A signal of a message (bb_signal_info). Its name and unit are bb_signal_name's and
 * bb_signal_unit's, its value table bb_signal_label's. physical = raw * factor + offset, the raw
 * value read as two's complement where is_signed. */
typedef struct bb_signal {
	int32_t start_bit;    /* as the DBC numbers it: Intel's least significant bit, Motorola's most */
	int32_t length;       /* in bits */
	uint8_t big_endian;   /* Motorola (@0); 0 is Intel (@1) */
	uint8_t is_signed;
	uint8_t multiplexor;  /* the message's switch: which multiplexed signals the frame carries */
	uint8_t multiplexed;  /* present only where the switch reads mux_value */
	int32_t mux_value;
	int32_t labels;       /* value-table entries: bb_signal_label's k is 0 .. labels - 1 */
	double  factor;
	double  offset;
	double  minimum;      /* the DBC's [min|max], both 0 where it states none; NOT applied by
	                         bb_encode, which only keeps a value within the signal's width */
	double  maximum;
} bb_signal;

/* What bb_uds_open opened: the ids a request goes out and its answer comes back on, as resolved
 * from what was asked (an omitted one is the default, 0x7E0 / 0x7E8). */
typedef struct bb_uds_target {
	uint32_t tx;
	uint32_t rx;
	uint8_t  ext;   /* 29-bit: either id is past 0x7FF */
} bb_uds_target;

/* One request a UDS handle put through (bb_uds_last), answered or not. */
typedef struct bb_uds_exchange {
	uint8_t sent;         /* the request went out whole; 0: it failed before or during its send,
	                         so the ECU never had all of it, and repeating it does not ask twice */
	uint8_t negative;     /* the answer was a negative response, ... */
	uint8_t nrc;          /* ... with this code (0 otherwise) */
	int32_t pending;      /* how many responsePending (0x78) came before the answer */
	int64_t rtt_us;       /* from the send to the final answer, or to the failure */
	int64_t pending_us;   /* from the first 0x78 to the end; 0 without one */
	int32_t request_len;  /* the request as it went out (a suppressed one with its bit set) */
	int32_t answer_len;   /* the positive answer, a negative one's 7F <sid> <nrc>, an undecodable
	                         one as it came; 0: none came */
} bb_uds_exchange;

/* Error codes. The message (bb_last_error) says what; the code says which kind. */
#define BB_ERR         (-1)  /* refused, with a reason in bb_last_error */
#define BB_ERR_HANDLE  (-2)  /* no such bus or UDS handle, or a closed one */
#define BB_ERR_STATE   (-3)  /* nothing loaded / not started / already started / still releasing */
/* how a UDS call failed (bb_uds_*); BB_ERR there is a refusal: the request did not go out whole
 * (an argument out of range, a request longer than ISO-TP carries, a listen-only wire), or a
 * reason the message gives */
#define BB_ERR_NEGATIVE     (-4)  /* the ECU answered with a negative response: bb_uds_last's nrc */
#define BB_ERR_TIMEOUT      (-5)  /* nothing answered the request within the wait */
#define BB_ERR_PENDING      (-6)  /* responsePending (0x78), then nothing within the ECU's P2* */
#define BB_ERR_UNDECODABLE  (-7)  /* an answer arrived that cannot be read as one */
#define BB_ERR_CARRIER      (-8)  /* the carrier failed under the request: the bus, or the ISO-TP
                                     channel (a frame lost mid-transfer) */

/* Answers that are neither success nor an error. */
#define BB_NONE        1     /* bb_bus_recv: no frame in time; bb_decode: no message */
#define BB_SPENT       2     /* bb_bus_recv with timeout 0: no frame yet, but the look stopped at
                                its bound with records still queued — look again at once rather
                                than sleeping (transport.look_was_spent) */
#define BB_RELEASING   3     /* bb_stop: the run is stopped, but a loop outlived the stop's bound
                                and is still letting go of its wires; bb_start refuses with
                                BB_ERR_STATE until bb_wait_released says it is done */
#define BB_ANSWERED    4     /* bb_uds_raw_suppressed: a positive answer came although none was
                                asked for (the ECU ignored the suppress bit) */

#define BB_ERROR_MAX   4095  /* the longest bb_last_error message, in bytes */

/* The prototypes are for hosts. V compiles the types and codes above and declares the
 * functions itself (there is no const in V, so its `char *` would clash with these). */
#ifndef BB_FROM_V
const char *bb_version(void);      /* the library's version, v.mod's */
int         bb_init(void);
const char *bb_last_error(void);   /* "" when the last call succeeded */
int         bb_thread_attach(void); /* on a host-created thread, before its first other call */
int         bb_thread_detach(void); /* on that thread, before it ends */

/* A project (.blobnet): load reads it; start brings its enabled rows up — simulated ECUs, UDS
 * servers, generators, DoIP entities — through blobly.headless, one run per process; stop ends
 * the run and frees the process for the next start (0), or answers BB_RELEASING when a loop
 * outlived the stop's bound (a driver call that will not return): then bb_wait_released waits
 * for it, and bb_start refuses with BB_ERR_STATE until it has. */
int bb_load(const char *project_path);
int bb_start(void);
int bb_stop(void);
int bb_wait_released(int timeout_ms);  /* 0: free for a start; BB_RELEASING: not within the
                                          timeout (< 0 waits until it is) */

/* The loaded project's ENABLED rows, in project order. */
int         bb_channel_count(void);
const char *bb_channel_name(int i);
const char *bb_channel_iface(int i);   /* while started, as the run has it (a hosted DoIP row
                                          moves onto a port this process could bind); otherwise
                                          as the project says */
int         bb_channel_kind(int i);    /* >= 0: an enum bb_kind; only BB_KIND_CAN opens */
int         bb_channel_health_source(int i); /* >= 0: an enum bb_health_source */

/* A bus handle of the host's own on a CAN interface ("inproc:CAN1", "vcan0",
 * "pcan:PCAN_USBBUS1@500000"); a DoIP or SOME/IP endpoint is refused by name. */
int bb_bus_open(const char *iface);                          /* >= 0: the handle */
int bb_bus_send(int h, const bb_frame *f);
int bb_bus_recv(int h, int timeout_ms, bb_frame *out);       /* 0: a frame; BB_NONE: none in
                                                                time; BB_SPENT: see above (only
                                                                with timeout 0); timeout < 0
                                                                waits for a frame */
int bb_bus_health(int h);                                    /* >= 0: an enum bb_health */
int bb_bus_close(int h);  /* a send or recv on another thread ends first (a recv within 20 ms,
                             with BB_ERR_HANDLE); the handle is then closed and its index never
                             reused */

/* A row's databases: the merge of its `databases:` that the RUN loaded — the one its simulated
 * ECUs encode by and a Lua script's bus.send_message and decode read — from bb_start until
 * bb_stop (BB_ERR_STATE otherwise). `row` is a bb_channel_* index; m is 0 .. bb_message_count - 1,
 * s 0 .. that message's signals - 1. Every call here only reads, and may come from any thread
 * (attached, as ever): one racing bb_stop answers from the run's databases or BB_ERR_STATE.
 *
 * A string goes into the caller's buffer, `cap` bytes with its NUL: the answer is the string's
 * whole length in bytes, so one at or past cap was cut (at a byte) and wants a buffer of the
 * answer + 1. cap 0 (buf may be NULL) asks for the length alone. */
int bb_message_count(int row);                                  /* >= 0: how many */
int bb_message_info(int row, int m, bb_message *out);
int bb_message_name(int row, int m, char *buf, int cap);        /* >= 0: the length */
int bb_signal_info(int row, int m, int s, bb_signal *out);
int bb_signal_name(int row, int m, int s, char *buf, int cap);  /* >= 0: the length */
int bb_signal_unit(int row, int m, int s, char *buf, int cap);  /* >= 0: the length */
int bb_signal_label(int row, int m, int s, int k, uint64_t *raw, double *value, char *buf,
                    int cap);                                   /* >= 0: the label's length;
                                                                   *raw (unless NULL) the key the
                                                                   table gives it — the field's
                                                                   bits, two's complement for a
                                                                   signed signal — and *value
                                                                   (unless NULL) the physical
                                                                   value it names, which a double
                                                                   may not tell from another's
                                                                   past 2^53 */

/* The frame message m sends with signals[i] at the physical values[i] (i < n) and every other
 * signal at raw 0, as bus.send_message encodes it: a name the message does not have is refused;
 * a value past what the signal's width holds is clamped to the nearer end, NaN encodes as raw 0.
 * out gets the message's id, ext and dlc as len; fd and brs are left unset, so a send takes the
 * wire's declared format. */
int bb_encode(int row, int m, int n, const char *const *signals, const double *values,
              bb_frame *out);

/* What a frame says in the row's databases: 0 with *message the message it decodes as (its id and
 * kind, else for an extended frame one of its J1939 PGN), and for each of its signals s < cap
 * values[s] its physical value and active[s] whether the frame carries it (1), or not (0,
 * values[s] 0): a multiplexed signal its switch does not select, or a signal whose bits a short
 * payload does not all hold (nor its multiplexor's); BB_NONE for no message, or a
 * remote frame (no data). The arrays hold `cap`: a message of more signals is refused, with
 * *message set so the host can ask again with arrays of its bb_message.signals. */
int bb_decode(int row, const bb_frame *f, int *message, double *values, uint8_t *active, int cap);

/* UDS (ISO 14229) on a CAN row: a client over ISO-TP on the row's bus, opened by the rule a Lua
 * script's uds.open opens by (blobly/udsconn), each call one of its helpers — so a host reads
 * answers decoded and failures typed, and never a UDS payload of its own. A DoIP row is refused
 * by name: UDS over DoIP is not in this library yet. `row` is a bb_channel_* index; tx / rx point
 * at the ids to use, NULL for the default (0x7E0 / 0x7E8): an id that is not a CAN identifier is
 * refused, and either past 0x7FF makes both 29-bit. `out` (unless NULL) gets the ids opened on.
 *
 * ONE THREAD USES A UDS HANDLE at a time, as a bus handle; bb_uds_close may come from another,
 * and ends a call in progress there (BB_ERR_HANDLE) within 20 ms of the wait it is in — a frame
 * already handed to the driver is written first, which the backend's own send timeout bounds. A
 * handle outlives bb_stop (with nothing to answer it, once the run's simulated ECUs are gone):
 * close it.
 *
 * EVERY CALL IS BOUNDED by the client's timing (blobly/uds): the first answer within 1000 ms (a
 * 0x10 answer's P2 can lengthen that, never shorten it), each responsePending (0x78) then waited
 * for the ECU's P2* + 1000 ms, and one request never longer than 120 s from its send. A failure
 * is one of the BB_ERR_* above, its words in bb_last_error; a negative response's NRC is
 * bb_last_nrc's, per thread as the words are.
 *
 * Bytes a call answers (a DID's value, a seed, an answer) go into the caller's buffer, `cap`
 * bytes, and the answer is their whole length: past cap they were cut, and bb_uds_data copies
 * them again, whole, until the handle's next call. cap 0 (buf may be NULL) asks for the length
 * alone. */
int bb_uds_open(int row, const int64_t *tx, const int64_t *rx, bb_uds_target *out);
                                       /* >= 0: the handle; BB_ERR_STATE until bb_start, which
                                          publishes the wires' policy (listen-only, framing) */
int bb_last_nrc(uint8_t *nrc);  /* 0 with *nrc the NRC when the calling thread's last call failed
                                   with BB_ERR_NEGATIVE, BB_NONE otherwise; like bb_last_error it
                                   changes nothing, so it answers after the handle is gone */
int bb_uds_close(int u);
int bb_uds_last(int u, bb_uds_exchange *out, uint8_t *request, int request_cap, uint8_t *answer,
                int answer_cap);                            /* 0, with the handle's last exchange
                                                               (its bytes cut at the caps, the
                                                               struct saying their lengths), or
                                                               BB_NONE before its first */
int bb_uds_data(int u, uint8_t *buf, int cap);             /* the last call's bytes, again
                                                               (none after a call that failed or
                                                               answers none) */
int bb_uds_raw(int u, const uint8_t *req, int n, uint8_t *buf, int cap); /* the positive answer,
                                                                            its SID included */
int bb_uds_raw_suppressed(int u, const uint8_t *req, int n); /* req's sub-function sent with
                                                                suppress-positive-response: 0 when
                                                                no positive answer came (a quiet P2
                                                                is success), BB_ANSWERED when one
                                                                did; a refusal is an error */
int bb_uds_session(int u, int session, uint8_t *buf, int cap); /* 0x10: the answer after its SID —
                                                                  the session, then its timing.
                                                                  A sub-function with the
                                                                  suppress bit (0x80) is refused
                                                                  here and by reset and
                                                                  comm_control: no answer would
                                                                  come (bb_uds_raw_suppressed) */
int bb_uds_tester_present(int u);                           /* 0x3E 00 */
int bb_uds_read_did(int u, int did, uint8_t *buf, int cap); /* 0x22: the DID's value */
int bb_uds_write_did(int u, int did, const uint8_t *data, int n); /* 0x2E */
int bb_uds_reset(int u, int kind, uint8_t *buf, int cap);   /* 0x11: the answer after its SID */
int bb_uds_comm_control(int u, int control, int comm_type); /* 0x28 */
int bb_uds_dtc_setting(int u, int on);                      /* 0x85: on (1) or off (0) */
int bb_uds_clear_dtcs(int u, int group);                    /* 0x14: a DTC or a group, 24 bits
                                                               (0xFFFFFF: all) */
int bb_uds_security_seed(int u, int level, uint8_t *unlocked, uint8_t *buf, int cap);
                                       /* 0x27 at an odd level (an even one is refused): the
                                          seed; *unlocked (unless NULL) 1 when it is all zeros,
                                          ISO 14229-1's "already unlocked", for which no key is
                                          to be sent */
int bb_uds_security_key(int u, int level, const uint8_t *key, int n); /* 0x27 at an even level
                                                                         (the seed's + 1; odd
                                                                         refused) */
int bb_reference_key(const uint8_t *seed, int n, uint8_t *buf, int cap); /* blobly_net's
                                       reference key for a seed (each byte XOR 0xFF): the key the
                                       simulated ECUs accept */
int bb_nrc_name(int nrc, char *buf, int cap);  /* ISO 14229-1's name for a negative response
                                                  code, a string into the buffer as
                                                  bb_message_name's */

/* Faults and E2E: the rules the Lua prelude's sim.fault and e2e.* ask (cmd/libblobly/sim.v).
 *
 * bb_sim_fault arms a fault on a simulated node's message on row `row` of the run (from bb_start
 * until bb_stop, BB_ERR_STATE otherwise; any thread). `kind` is "drop", "bad_crc",
 * "freeze_counter" or "out_of_range"; "clear" lifts the message's fault. `ms` > 0 ends it after
 * that long, 0 or less leaves it until cleared. `signal` (NULL or "": one is chosen) is the one
 * out_of_range forces past its declared range. A fault that could not take effect is refused with
 * BB_ERR, as Lua refuses it: a DoIP or SOME/IP row, an unknown kind, a node not simulated on
 * the row, a message `node` does not send, bad_crc where it stamps no checksum, freeze_counter where it stamps no E2E counter,
 * out_of_range where no signal can carry a value outside its range. The faults are the process's,
 * and a bb_start clears them. bb_sim_clear_faults lifts every one. */
int bb_sim_fault(int row, const char *node, const char *message, const char *kind, int ms,
                 const char *signal);
int bb_sim_clear_faults(void);

/* AUTOSAR E2E Profile 1 for a frame of n bytes the host built, computed as the simulation stamps
 * it: CRC-8 poly 0x1D, start 0, no final XOR, over the Data ID bytes `mode` names (NULL or "" is
 * "both": low then high; "low"; "alt": low for an even counter, high for an odd one), then every
 * byte but the CRC's. `data_id` is 0..0xFFFF; crc_pos and counter_pos are distinct bytes of the
 * frame, the counter in counter_pos's low nibble. Anything else is refused with BB_ERR. */
int bb_e2e_p01_crc(const uint8_t *data, int n, int data_id, int crc_pos, int counter_pos,
                   const char *mode);                            /* >= 0: the CRC byte */
int bb_e2e_p01_protect(uint8_t *data, int n, int data_id, int crc_pos, int counter_pos,
                       int counter, const char *mode);           /* in place: `counter` (0..14)
                                                                    into counter_pos's low nibble,
                                                                    then the CRC at crc_pos */
#endif /* BB_FROM_V */

#ifdef __cplusplus
}
#endif

#endif /* BLOBLY_BB_H */
