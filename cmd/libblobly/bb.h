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
 *   - ONE THREAD USES A BUS HANDLE: its send, recv, health, load and diagnostics calls come from
 *     one thread at a time — which may be an attached thread of its own, not the driver's. The backends are not
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
 * truncated. `t_ns` is when a received frame arrived, on the host's monotonic clock (bb_now_ns), in
 * nanoseconds: the frame's own receive stamp where the backend reads one (SocketCAN's kernel stamp;
 * a foreign device clock mapped onto the host's) — the time the GUI's trace gives that frame —
 * else its receipt, when this call read it. Ignored on a send; 0 from bb_encode. `e2e` is a
 * received frame's E2E verdict, an enum bb_e2e: BB_E2E_NONE (0) unless the handle that read it was
 * bound to a row by bb_e2e_attach and the frame's message has E2E there; ignored on a send. The
 * layout may grow between versions until the ABI has a stability policy (#507 Phase 3): a host is
 * built against the bb.h of the library it loads, as the Python package ships with its own. */
typedef struct bb_frame {
	uint32_t id;
	uint8_t  len;
	uint8_t  ext;
	uint8_t  fd;
	uint8_t  brs;
	uint8_t  rtr;
	uint8_t  esi;
	uint8_t  data[64];
	uint8_t  e2e;
	int64_t  t_ns;
} bb_frame;

/* A received frame's E2E verdict (bb_frame.e2e, "E2E on a row's frames" below). */
enum bb_e2e {
	BB_E2E_NONE = 0,       /* not judged: no E2E for its message on the row, or a remote frame */
	BB_E2E_OK = 1,
	BB_E2E_BAD_CRC = 2,    /* the CRC does not match the frame's bytes */
	BB_E2E_REPEATED = 3,   /* the counter repeated the previous frame's: no new data */
	BB_E2E_SKIPPED = 4,    /* the counter jumped (frames lost, or the sender restarted), or holds a
	                          value the profile never sends (Profile 1's 15) */
	BB_E2E_TRUNCATED = 5,  /* shorter than its message: its E2E fields are not all there */
	BB_E2E_TIMEOUT = 6     /* later than its message's E2ETimeout after the last valid frame */
};

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

/* What bb_uds_open opened: on a CAN row the ids a request goes out and its answer comes back on,
 * as resolved from what was asked (an omitted one is the default, 0x7E0 / 0x7E8); on a DoIP row the
 * logical addresses, tx the tester's (the requests' source) and rx the ECU's (their target), ext 0. */
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

/* A DTC as the ECU reported it (bb_uds_dtc, bb_uds_snapshot, bb_uds_extended). Its status bits
 * are named by bb_dtc_status_bit; its display name (U0121-00) is bb_dtc_name's. */
typedef struct bb_dtc {
	uint32_t code;          /* 24 bits: the DTC and its failure-type byte */
	uint8_t  status;        /* ISO 14229-1's status byte */
	uint8_t  availability;  /* the status bits the ECU reports: the 0x19 02 / 0A answer's mask,
	                           0xFF where an answer carries none (0x19 04 / 06) */
} bb_dtc;

/* blobly_emb's extended data records as what they count (bb_uds_extended): record 0x01 the
 * occurrences, 0x02 the aging counter, 0x03 the failed operation cycles. */
typedef struct bb_counters {
	uint64_t occurrences;
	uint64_t aging;
	uint64_t failed_cycles;
	uint8_t  has;  /* which the answer carried: bit 0 occurrences, bit 1 aging, bit 2 failed
	                  cycles (absent is not zero) */
} bb_counters;

/* What one target answered a functional request (bb_uds_functional). */
enum bb_functional_outcome {
	BB_FUNCTIONAL_POSITIVE = 0,
	BB_FUNCTIONAL_NEGATIVE = 1,  /* nrc says which */
	BB_FUNCTIONAL_SILENT = 2,    /* nothing within the window: normal for a functional request,
	                                which ISO 14229-1 has a server not refuse with 0x11, 0x12,
	                                0x31, 0x7E or 0x7F, and what a suppressed positive response is */
	BB_FUNCTIONAL_PENDING = 3,   /* responsePending (0x78), then nothing within its P2* */
	BB_FUNCTIONAL_FAILED = 4     /* an answer that cannot be read, or the channel failing while
	                                reading one: bb_uds_reply_error says which */
};
typedef struct bb_functional_reply {
	int32_t outcome;     /* an enum bb_functional_outcome */
	uint8_t nrc;         /* a negative answer's code */
	uint8_t pended;      /* responsePending (0x78) came on the way */
	int32_t answer_len;  /* the answer (positive, or 7F <sid> <nrc>): the target handle's
	                        bb_uds_data */
} bb_functional_reply;

/* What a DoIP entity says about itself (bb_doip_discover, bb_doip_listen): a vehicle
 * identification response, or an announcement it sent unasked — the same message (ISO 13400-2). */
#define BB_DOIP_SOURCE_MAX 96
typedef struct bb_doip_announcement {
	char     vin[18];          /* the VIN as text; "" when the entity has none (ISO 13400 fills an
	                              unconfigured one with 0x00 or 0xFF) or it is not printable ASCII */
	uint16_t logical_address;
	uint8_t  eid[6];           /* the entity id (often its MAC address) */
	uint8_t  gid[6];           /* the group id */
	char     source[BB_DOIP_SOURCE_MAX]; /* where it came from, "host:port" ("[v6]:port"); a
	                                        longer one is cut at a byte */
} bb_doip_announcement;

/* A SOME/IP message to send (bb_someip_send, bb_someip_call). A field of -1 takes its default:
 * `msg_type` a notification (0x02) for an event id (bit 15 of `method`), a request (0x00)
 * otherwise — only those two are sent; `iface` (the interface version) 1; `client` 0x1234 for a
 * request (a blobly_emb node refuses client 0), 0 for a notification; `session` the run's next for
 * a request (0 too), 0 for a notification. A request's session, given or not, goes out once per
 * run (bb_start begins one): a late reply to one request can never complete another. */
typedef struct bb_someip_out {
	uint16_t       service;
	uint16_t       method;
	int32_t        msg_type;
	int32_t        iface;
	int32_t        client;
	int32_t        session;
	const uint8_t *payload;
	int32_t        payload_len;
} bb_someip_out;

/* A SOME/IP message a capture holds (bb_someip_msg): heard on a port, or a call's answer. */
#define BB_SOMEIP_FROM_MAX 64
typedef struct bb_someip_msg {
	uint16_t service;
	uint16_t method;       /* an event id has bit 15 set */
	uint16_t client;
	uint16_t session;
	uint8_t  iface;        /* the interface version */
	uint8_t  msg_type;     /* 0x00 request, 0x02 notification, 0x80 response, 0x81 error */
	uint8_t  return_code;
	uint8_t  protocol;     /* the protocol version (0x01 is the only one SOME/IP defines) */
	int32_t  payload_len;
	int64_t  at_ms;        /* ms into the window it was heard in; a call's answer, ms after the send */
	char     from[BB_SOMEIP_FROM_MAX]; /* where it came from, "host:port"; a longer one is cut */
} bb_someip_msg;

/* How a flash's 0x29 authentication went (bb_flash_report.auth). */
enum bb_flash_auth {
	BB_FLASH_SKIPPED = 0,        /* auth 0: no seed */
	BB_FLASH_AUTHENTICATED = 1,
	BB_FLASH_NOT_REQUIRED = 2    /* a keyless boot refused the challenge (0x22 / 0x11) */
};

/* A flash's options (bb_flash_program); bb_flash_defaults fills every field. `base` is where the
 * image goes (0x08020000, the app slot), `sw_version` the version a raw image's header states
 * (1). With `auth` (1) the session signs the bootloader's 0x29 challenge with the tester seed:
 * `seed` (64 hex characters), else the file `seed_file` names, else $BLOBLY_FLASH_SEED, else the
 * dev tester seed; both, or either with auth 0, is refused. `note` is called with each milestone
 * line, and — without `progress` — a line per tenth of the transfer; `progress` with the blocks
 * done and the total, at each whole percent and the last block; `quiet` 1 calls `note` never.
 * Either may be NULL; both are called on the thread calling bb_flash_program, with `ctx`. */
typedef struct bb_flash_opts {
	uint32_t    base;
	uint32_t    sw_version;
	int32_t     auth;
	const char *seed;
	const char *seed_file;
	int32_t     quiet;
	void (*note)(void *ctx, const char *line);
	void (*progress)(void *ctx, int32_t done, int32_t total);
	void       *ctx;
} bb_flash_opts;

/* What a completed flash did (bb_flash_program). */
typedef struct bb_flash_report {
	int32_t bytes;               /* header + image, as transferred */
	int32_t blocks;              /* 0x36 requests */
	uint8_t wrapped;             /* the image was a pre-wrapped BLBT .img, transferred as is */
	uint8_t reset_acknowledged;  /* the 0x11 reset was answered (0: its answer lost to the reset) */
	int32_t auth;                /* an enum bb_flash_auth */
} bb_flash_report;

/* What a simulated bootloader was asked to do (bb_boot_sim_stop). */
typedef struct bb_boot_report {
	uint8_t authenticated;  /* the last 0x29 proof verified against the dev tester key */
	uint8_t verified;       /* the last check routine passed: the CRC the image header states */
	int32_t erases;         /* 0x31 FF00 answered */
	int32_t blocks;         /* 0x36 blocks taken */
	int32_t bytes;          /* what the last download was sent, header included */
	int32_t checks;         /* 0x31 FF01 answered */
	int32_t resets;         /* 0x11 answered */
} bb_boot_report;

/* Bus metrics of a bus handle (bb_bus_load, bb_bus_diagnostics), from the call on the handle's
 * thread. The load is of DECODED frames only, both directions: what the handle receives (counted
 * when it is read, so a frame left queued lands in the second it is read) and what it sends once
 * the driver accepted it. Error frames, retransmissions and overrun drops occupied the wire and
 * are not in it: in an error storm it under-reads, and the health ladder and the diagnostics
 * counts are what say so. A frame costs its bit-times with worst-case stuffing (the GUI's bus
 * load), priced at the rates of the wire's first enabled row (`nominal`); an interface no row
 * names at the rate its address states (`pcan:...@250000`), else 500 kbit/s classic. */
typedef struct bb_busload {
	double   percent;   /* over the last whole second; < 0 until one second has passed */
	double   average;   /* since the handle opened; < 0 until one second has passed */
	double   bits;      /* nominal bit-times counted since open */
	uint64_t frames;    /* frames counted since open */
	int32_t  nominal;   /* the arbitration rate they are priced at, bit/s */
} bb_busload;

/* What the backend counted since the handle opened that no frame carried (transport.BusDiagnostics):
 * records dropped before delivery (a receiver that fell behind, a driver overrun, a shared ring
 * overwritten), controller error records, records it could not decode. On a wire shared through
 * one driver handle (PCAN, CANsub, the CAN bridge) they are the wire's since it opened, its other
 * handles' ring gaps included. */
typedef struct bb_diagnostics {
	uint64_t dropped;
	uint64_t bus_errors;
	uint64_t decode_errors;
} bb_diagnostics;

/* Where the CAN bridge of a WSL distribution stands (bb_bridge_state). */
enum bb_bridge_state {
	BB_BRIDGE_IDLE = 0,       /* not connected, not starting */
	BB_BRIDGE_STARTING = 1,   /* started; not dialled in yet */
	BB_BRIDGE_CONNECTED = 2,  /* dialled in: its channels open (bb_bridge_rows) */
	BB_BRIDGE_FAILED = 3      /* could not start, or did not dial in within 20 s: the reason says why */
};

/* A generator of the run (bb_gen_info); its name and the rest are bb_gen_text's. */
typedef struct bb_generator {
	uint32_t id;        /* the frame's id: its message's, for one with a message */
	uint8_t  ext;       /* a 29-bit identifier */
	uint8_t  running;   /* sending on its cycle now */
	uint8_t  sendable;  /* it has a bus to send on; BB_GEN_NOTE says why not */
	int32_t  cycle_ms;  /* its cycle, 0 for none */
	int64_t  sent;      /* frames its bus took, fired and cyclic alike */
} bb_generator;

/* What bb_gen_text copies out. */
enum bb_gen_text {
	BB_GEN_NAME = 0,
	BB_GEN_CHANNEL = 1,  /* the channel it is written under (a disabled row's too) */
	BB_GEN_MESSAGE = 2,  /* its DBC message, "" for a raw frame */
	BB_GEN_TRIGGER = 3,  /* as the project writes it: "manual", "key" or "cyclic" */
	BB_GEN_TARGET = 4,   /* the interface it sends on, "" for none */
	BB_GEN_NOTE = 5      /* why it cannot send, "" when it can */
};

/* A signal's value source (bb_gen_source), the parameters a project's `senders:` signal writes:
 * `kind` is "const", "sine", "sawtooth", "counter" or "stepmod", and each reads its own (const:
 * value; sine: offset, amplitude, freq, phase; sawtooth: min, max, period; counter: start, step,
 * modulo; stepmod: period, count, base). */
typedef struct bb_wave {
	const char *kind;
	double value, offset, amplitude, freq, phase, min, max, period, start, step, modulo, count, base;
} bb_wave;

/* Replay and recording (bb_replay_*, bb_record_*). */
enum bb_replay_state {   /* player.State */
	BB_REPLAY_STOPPED = 0,   /* not reported: a replay starts playing or paused, and `ended` says it was stopped */
	BB_REPLAY_PLAYING = 1,
	BB_REPLAY_PAUSED = 2,
	BB_REPLAY_FINISHED = 3   /* a non-looping replay ran out; resuming starts it again */
};

/* How a replay starts (bb_replay_start); bb_replay_defaults fills every field with "the rows'". */
typedef struct bb_replay_opts {
	const char *source;   /* the recording (.log or .mf4); NULL or "": the rows' replay: source */
	double      speed;    /* the rate; 0 or less: the rows' (1 for a row without a replay: block) */
	int32_t     loop;     /* 1 loop, 0 play once, -1 the rows' */
	int32_t     paused;   /* 1: start paused at the beginning */
	const char *exclude;  /* the nodes subtracted by DBC sender, one per line, in place of each
	                         row's own; NULL: the rows' */
	const char *bus;      /* the recorded bus, for one row; NULL or "": the row's */
} bb_replay_opts;

/* What a replay is doing (bb_replay_status, bb_replay_stop). */
typedef struct bb_replay_info {
	int32_t state;       /* an enum bb_replay_state */
	uint8_t loop;
	uint8_t ended;       /* stopped: its buses are let go */
	int32_t passes;      /* complete passes, the last of a non-looping replay included */
	double  position_s;  /* seconds into the recording */
	double  duration_s;
	double  speed;
	int64_t sent;        /* frames the drivers took since the replay (re)started */
	int64_t failed;      /* frames a driver refused: bb_replay_error names the first */
} bb_replay_info;

/* What a recording holds (bb_record_counts, bb_record_stop). */
typedef struct bb_record_report {
	int64_t frames;  /* lines written */
	int64_t ours;    /* frames this process sent (the tester, a simulated ECU, a replay): " T" */
	int64_t theirs;  /* frames nobody here sent: " R" */
	int64_t missed;  /* frames this process sent that never came back to the recorder (not written) */
	int64_t dropped; /* frames the recorder's own handles lost before it read them (Bus.diagnostics) */
} bb_record_report;
/* The system model: a node of the run's system.toml (bb_node_info). Its name is bb_node_name's. */
typedef struct bb_node {
	int32_t dids;           /* the DIDs it lists, bb_did_*'s d 0 .. dids - 1: its description's own,
	                           then the ISO identification DIDs it does not declare */
	int32_t faults;         /* its ecu.toml's [[fault]]s: bb_node_fault's k */
	int32_t targets;        /* the run's rows it is reached on: bb_node_target's k */
	uint8_t described;      /* its ecu.toml was read; else bb_node_problem says why, and it lists
	                           only the ISO DIDs */
	uint8_t server;         /* its ecu.toml declares a diagnostic server ([uds], [isotp] or [doip]) */
	uint8_t reference_key;  /* [uds] security_key = "reference": blobly_net's reference key
	                           (bb_reference_key) unlocks it */
} bb_node;

/* Where a node is reached on a row of the run (bb_node_target, bb_node_reach): a CAN row named
 * after a bus its server is on, at its diagnostic ids — what bb_uds_open's tx and rx are — or a
 * DoIP row whose entity is the node, opened with NULL ids. */
typedef struct bb_reach {
	int32_t  row;   /* a bb_channel_* index */
	uint8_t  doip;  /* the DoIP row's own connection: tx and rx 0 */
	uint8_t  ext;   /* 29-bit ids: either is past 0x7FF */
	uint32_t tx;    /* the node's request id */
	uint32_t rx;    /* its response id */
} bb_reach;

/* Where a DID's value comes from (bb_did.kind), as the ecu.toml declares it. */
enum bb_did_kind {
	BB_DID_ASCII = 0,           /* a fixed text */
	BB_DID_BYTES = 1,           /* fixed bytes */
	BB_DID_SIGNAL = 2,          /* a live signal's value */
	BB_DID_PARAM = 3,           /* a coded parameter */
	BB_DID_PARAM_STATUS = 4,    /* one status byte per parameter: 0 default, 1 coded, 2 reverted */
	BB_DID_TX_SATURATIONS = 5,  /* how many sent values were held to their DBC range */
	BB_DID_UNKNOWN = 6          /* none of these, or not declared: its bytes, of no known layout */
};

/* A DID a node lists (bb_did_info). Its name is bb_did_name's, a gate's sessions bb_did_session's. */
typedef struct bb_did {
	uint16_t id;
	int32_t  kind;            /* an enum bb_did_kind */
	int32_t  size;            /* its value's bytes; -1: the description does not say */
	int32_t  parts;           /* what its value is read and written as: bb_did_part's p */
	uint8_t  by_label;        /* its value is its parts by label (several, or a parameter
	                             status, whose parts are its parameters); else its one part's */
	uint8_t  read_gated;      /* a read gate is declared (else it reads in any session, unlocked) */
	int32_t  read_sessions;   /* the sessions it reads in, by name: none = any */
	int32_t  read_level;      /* the security level it reads at; 0 = none */
	uint8_t  writable;        /* a write gate is declared; without one it is not writable */
	int32_t  write_sessions;
	int32_t  write_level;
} bb_did;

/* What one part of a DID's value holds (bb_did_part): its text is an integer in decimal, true or
 * false, a text, or bytes in hex. */
enum bb_part_kind {
	BB_PART_INTEGER = 0,
	BB_PART_BOOLEAN = 1,
	BB_PART_TEXT = 2,
	BB_PART_BYTES = 3
};

/* What a gated write needs first (bb_uds_write_described, BB_ERR_GATED). */
typedef struct bb_write_needs {
	uint8_t session;  /* the session to switch to (0x10); 0 = the one the connection is in */
	uint8_t level;    /* the security level to unlock (0x27 2L-1 / 2L); 0 = none */
} bb_write_needs;

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
                                     channel (a frame lost mid-transfer); on a DoIP row a
                                     negative acknowledgement, or a connection that could not be
                                     opened (refused, no routing activation answer) */
#define BB_ERR_ROUTING      (-9)  /* bb_uds_open on a DoIP row: the entity denied the routing
                                     activation; bb_last_routing says with which code */
#define BB_ERR_LOST         (-10) /* the DoIP connection is gone (closed by the entity, reset, or
                                     stalled inside a message): nothing more goes over it — close
                                     the handle, and a new one opens a new connection */
#define BB_ERR_FLASH        (-11) /* bb_flash_program: the session ran and the bootloader's own
                                     answers say the flash did not happen (an erase or check
                                     routine's result, a malformed download answer), or it was
                                     cancelled; a step the bootloader refused or did not answer is
                                     that step's UDS failure (BB_ERR_NEGATIVE, BB_ERR_TIMEOUT ...) */
#define BB_ERR_E2E          (-12) /* returned by no call: the code a host gives a received frame
                                     that failed its E2E check (bb_frame.e2e) where it required it to
                                     pass, so every host's codes are one list */
#define BB_ERR_GATED        (-13) /* bb_uds_write_described: not sent, since the connection has not
                                     established the session or the security level the DID's
                                     write gate needs; bb_write_needs says which */

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
int64_t     bb_now_ns(void);       /* the host's monotonic clock, in ns: a received frame's t_ns */

/* A project (.blobnet): load reads it; start brings its enabled rows up — simulated ECUs, UDS
 * servers, generators, DoIP entities — through blobly.headless, one run per process; stop ends
 * the run and frees the process for the next start (0), or answers BB_RELEASING when a loop
 * outlived the stop's bound (a driver call that will not return): then bb_wait_released waits
 * for it, and bb_start refuses with BB_ERR_STATE until it has. bb_load publishes the project's
 * wire policy (listen-only rows, CAN-FD framing), which every send — a bus handle's, a UDS
 * handle's — is checked against from then on, on a handle opened before the load, before bb_start
 * or across a stop too (a send refused on a listen-only row; the controller's own silence, where
 * the adapter has one, is set when a handle opens, and Vector and CANsub keep it); it refuses with BB_ERR_STATE while a stopped run is still releasing, whose
 * loops send under their own. Before the first load nothing is published, and a bus sends as its
 * backend has it. */
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

/* UDS (ISO 14229) on a row: a client over ISO-TP on a CAN row's bus, or over a DoIP row's
 * connection to its entity (ISO 13400: TCP, then routing activation), opened by the rule a Lua
 * script's uds.open opens by (blobly/udsconn), each call one of its helpers — so a host reads
 * answers decoded and failures typed, and never a UDS payload of its own. `row` is a bb_channel_*
 * index. On a CAN row tx / rx point at the ids to use, NULL for the default (0x7E0 / 0x7E8): an
 * id that is not a CAN identifier is refused, and either past 0x7FF makes both 29-bit. On a DoIP
 * row the addressing is the row's (tester_address / ecu_address), so tx / rx must be NULL; a
 * denied routing activation is BB_ERR_ROUTING, and a second handle on a row that has one open in
 * this run is refused — one tester address holds one connection to its entity (ISO 13400-2), so
 * the second's routing activation would be denied. The open is bounded: the TCP connect and the
 * routing activation within 7 s in all, the activation answer within 2 s of the connect; a write
 * on the connection within 2 s, after which it is lost. `out` (unless NULL) gets what was opened
 * on (bb_uds_target).
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
                                       /* >= 0: the handle; BB_ERR_STATE outside a run, whose
                                          rows it opens on (a hosted DoIP row's moved port) */
int bb_last_nrc(uint8_t *nrc);  /* 0 with *nrc the NRC when the calling thread's last call failed
                                   with BB_ERR_NEGATIVE, BB_NONE otherwise; like bb_last_error it
                                   changes nothing, so it answers after the handle is gone */
int bb_last_routing(uint8_t *code, uint16_t *tester); /* 0 with the routing activation response
                                   code and the tester address it was asked for, when the calling
                                   thread's last call failed with BB_ERR_ROUTING; BB_NONE
                                   otherwise. Per thread, as bb_last_nrc */
int bb_doip_routing_name(int code, char *buf, int cap);  /* ISO 13400-2's meaning of a routing
                                                            activation response code */
int bb_doip_routing_hint(int code, int tester, char *buf, int cap); /* what a tester asking as
                                   `tester` can do about a denial with `code`; "" where there is
                                   nothing to add to its name */
int bb_uds_close(int u);
int bb_uds_replaces(int u);  /* u's connection replaces an earlier one the host had (a client
                                reopened after a stop): on DoIP a 0x27 key is then refused until
                                its level's seed is answered on this connection, as after the
                                library reopens a lost one itself; nothing on CAN */
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

/* DTCs (0x19) as a model: a call answers how many entries the ECU gave, and its accessors read
 * them from the handle until its next call that asks the ECU anything (a failed one included).
 * `mask` is a status mask (0xFF: any bit), `code` a 24-bit DTC (bb_dtc_code from a name),
 * `record` a record number (0xFF: all). A
 * snapshot DID's size, which the answer does not carry, is learned by reading the DID (0x22)
 * once; bb_uds_did_size states it for one that cannot be read. */
int bb_uds_dtcs(int u, int mask);            /* 0x19 02: >= 0, how many DTCs have a bit of mask */
int bb_uds_supported_dtcs(int u);            /* 0x19 0A: >= 0, how many the ECU supports */
int bb_uds_dtc(int u, int i, bb_dtc *out);   /* DTC i of the last 0x19 02 / 0A */
int bb_uds_dtc_count(int u, int mask, uint8_t *availability); /* 0x19 01: >= 0, the count */
int bb_uds_snapshot_ids(int u);              /* 0x19 03: >= 0, how many (DTC, record) */
int bb_uds_snapshot_id(int u, int i, uint32_t *code, uint8_t *record);
int bb_uds_snapshot(int u, int code, int record, bb_dtc *dtc); /* 0x19 04: >= 0, how many
                                                                  records; *dtc its status */
int bb_uds_snapshot_record(int u, int r, uint8_t *number);     /* >= 0, how many DIDs */
int bb_uds_snapshot_did(int u, int r, int d, uint16_t *id, uint8_t *buf, int cap); /* the value */
int bb_uds_extended(int u, int code, int record, bb_dtc *dtc, bb_counters *counters);
                                             /* 0x19 06: >= 0, how many records */
int bb_uds_extended_record(int u, int k, uint8_t *number, uint8_t *buf, int cap); /* its bytes */
int bb_uds_did_size(int u, int did, int n);  /* a snapshot DID is n bytes */
int bb_uds_ext_record_size(int u, int record, int n); /* an extended record is n bytes (blobly_emb's
                                                         0x01..0x03 are known) */
int bb_dtc_name(int code, char *buf, int cap);         /* SAE J2012's display: U0121-00 */
int bb_dtc_code(const char *name, int *code);           /* 0, *code the name's ("U0121-00", or
                                                           "U0121" for failure type 00, either
                                                           case); BB_NONE for no DTC name */
int bb_dtc_status_bit(int k, uint8_t *mask, char *buf, int cap); /* ISO 14229-1's status bit k
                                                                    of the byte (0 testFailed ..
                                                                    7), its mask and name */

/* Functional addressing on a CAN row (ISO 14229-2 / 15765-2): `req` goes out ONCE, a Single
 * Frame (7 bytes at most) on id `id`, and each of the n handles (one at least) — opened on this
 * row in this run (BB_ERR_STATE before bb_start, or for a handle of an earlier run) — answers on
 * its own response id, a multi-frame answer included. out[i] is handles[i]'s reply; window_ms
 * bounds each target's first answer (0: 1000), a responsePending its P2* after. One thread uses
 * those handles for the call, and a close of any of them ends it. A DoIP row is
 * bb_uds_functional_doip's. */
int bb_uds_functional(int row, int64_t id, const int *handles, int n, const uint8_t *req, int len,
                      int window_ms, bb_functional_reply *out);
/* Functional addressing on a DoIP row (ISO 13400-2): `req` goes out on handle u's connection to
 * the functional logical address *address (NULL: 0xE400), and the entity the connection reaches
 * answers from its own address — one connection is one entity, so one reply, *out, its answer the
 * handle's bb_uds_data. window_ms bounds the first answer (0: 1000), a responsePending its P2*
 * after; a close of the handle ends it. BB_ERR_STATE for a handle of an earlier run, or after
 * bb_stop. */
int bb_uds_functional_doip(int u, const int64_t *address, const uint8_t *req, int len,
                           int window_ms, bb_functional_reply *out);
int bb_uds_reply_error(int u, char *buf, int cap);  /* why the handle's last functional reply
                                                      failed; "" when it did not. A functional
                                                      request leaves each target's bb_uds_last
                                                      BB_NONE: its reply is out[i] */

/* DoIP discovery (ISO 13400-2 vehicle identification), as the Lua doip.discover and doip.listen.
 *
 * bb_doip_endpoint is DoIP row `row`'s endpoint as the run has it (a hosted entity's port is the
 * run's): its host into the buffer, as bb_message_name's, its port into *port; BB_ERR_STATE before
 * bb_start, BB_ERR for a row that is not DoIP. bb_doip_listener is where to listen for that row's
 * announcements: on its port (a `port` other than 0 that contradicts it is refused) and, when its
 * address is IPv6 or ip6 is 1, over IPv6. A host resolving a row reads these under its own state
 * serialisation, then does the waiting below, which touches no state, from any (attached) thread.
 *
 * bb_doip_discover asks the entity at host:port who it is and waits at most timeout_ms: 0 with
 * *out filled (its source the answer's sender), BB_ERR_TIMEOUT when none came, BB_ERR for an
 * endpoint that cannot be asked.
 *
 * bb_doip_listen hears the announcements entities send unasked, for window_ms, on port `port`
 * (0: 13400) over IPv4, or over IPv6 (joining ff02::1) when ip6 is 1. Nothing is queued for a
 * listener that is not there, so it hears only what is sent within its window. Answers how many
 * it heard (>= 0), every one, in the order heard, the first `cap` of them in out[]. A listener in
 * this process holding the port exclusively (a SOME/IP row) is a refusal; ISO 13400 puts every
 * tester and entity on one discovery port, so DoIP listeners share it. */
int bb_doip_endpoint(int row, char *host, int cap, int *port);    /* >= 0: the host's length */
int bb_doip_listener(int row, int port, int ip6, int *use_port, int *use_ip6);
int bb_doip_discover(const char *host, int port, int timeout_ms, bb_doip_announcement *out);
int bb_doip_listen(int port, int window_ms, int ip6, bb_doip_announcement *out, int cap);

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
/* E2E on a row's frames (cmd/libblobly/e2e.v), the rules the Lua prelude's frame.e2e and
 * bus.send_message follow (blobly/sim e2e_script.v). From bb_start until bb_stop (BB_ERR_STATE
 * otherwise).
 *
 * bb_e2e_attach binds handle h to row `row` of the run: each frame bb_bus_recv reads on it from then
 * on carries its verdict in bb_frame.e2e, by its message's E2E on the row — the row's verify: entry
 * for it, else what its database declares (E2ECounterSignal, E2ECrcSignal, E2EProfile, E2EDataId);
 * a simulated node's protect: entry is its own word as a sender, not a receiver's contract. The
 * CRC; the counter against the frame of that id the handle read before it (so one it missed makes
 * the next a skip); and the time since the last valid frame (its CRC right, its counter new: not a
 * repeat, nor Profile 1's 15) against the message's E2ETimeout, measured between the frames' own
 * receive stamps in one clock domain (SocketCAN's kernel stamp, the CAN bridge's clock), never
 * their placement on the host's clock — a frame with no stamp (a software bus, an adapter that
 * reads none) is never late, and a valid one ends the gap being measured. Answers how many of the
 * row's messages are judged; 0 binds nothing. On the thread that uses the handle; the binding is
 * the run's, and a handle kept past bb_stop reads BB_E2E_NONE until it is attached again.
 *
 * bb_e2e_stamp writes message m's DECLARED E2E (its database's, as a simulated sender stamps it)
 * into f, m's frame from bb_encode: the counter the next of the run's sends of m by name on the row,
 * from 0, then the CRC over f's bytes; BB_NONE, f unchanged, where m declares none. A declaration
 * that cannot be applied (an unknown profile, a CRC signal that is not one byte ...) is refused with
 * BB_ERR rather than left unstamped, and so is a frame shorter than m's payload. A send that fails
 * after its stamp has still used its counter, as AUTOSAR's protect counts each frame it protects.
 * Any thread. */
int bb_e2e_attach(int h, int row);               /* >= 0: how many messages are judged */
int bb_e2e_stamp(int row, int m, bb_frame *f);

/* SOME/IP, as the Lua someip.send, someip.call and someip.listen (blobly/someip). None needs a
 * started project but listening on a row's endpoint; each blocks for its window or wait, touches
 * no state, and may come from any (attached) thread. A destination is an IPv4 "host:port"; the
 * local `port` is bound on the IPv4 wildcard, claimed like every listener of this process (one
 * held by a SOME/IP row, a script or another call is refused, since two sockets on one UDP port
 * split its stream).
 *
 * bb_someip_send sends msgs[0..n-1] to `to` FROM local `port` (0: 30491, for a call too; one
 * socket both ways: a node with a static peer endpoint answers only the port it was addressed
 * from), then hears that port for window_ms. bb_someip_call sends one request and waits at most
 * timeout_ms (more than 0) for the RESPONSE or ERROR mirroring its Request ID from `to` — an ERROR
 * is an answer, its return code in the message; events, other senders and stale replies are
 * skipped; BB_ERR_TIMEOUT when none came.
 * A call refuses an event id, client 0 and any type but a request. bb_someip_listen hears for
 * window_ms what the network already carries on `host` (NULL or "": the wildcard) and `port` (0:
 * 30490), joining `group` (NULL or "": none). Nothing is sent or subscribed to. bb_someip_listener
 * is where SOME/IP row `row` of the run listens: its bind host into `host` (as bb_message_name's),
 * its port into *use_port and its group into `use_group` (refused when it does not fit gcap) — a
 * `port` (0: the row's) or `group` (NULL or "": the row's) that contradicts the row is refused;
 * BB_ERR_STATE before bb_start. A host resolves a row under its own state serialisation, then
 * listens outside it, as for DoIP.
 *
 * Each answers a CAPTURE (>= 0): bb_someip_count says how many messages it holds (and, into
 * *malformed, how many datagrams could not be read to the end), bb_someip_message copies message
 * i out (its payload into buf, as bb_uds_data's: answers its length), and bb_someip_free lets it
 * go. A call's capture holds its answer. */
int bb_someip_send(int port, const char *to, const bb_someip_out *msgs, int n, int window_ms);
int bb_someip_call(int port, const char *to, const bb_someip_out *req, int timeout_ms);
int bb_someip_listener(int row, int port, const char *group, char *host, int hcap, int *use_port,
                       char *use_group, int gcap);                /* >= 0: the host's length */
int bb_someip_listen(const char *host, int port, const char *group, int window_ms);
int bb_someip_count(int capture, int *malformed);                 /* >= 0: the messages */
int bb_someip_message(int capture, int i, bb_someip_msg *out, uint8_t *buf, int cap);
int bb_someip_free(int capture);

/* Flashing a blobly_emb bootloader (blobly/flash: 0x10 02, 0x29, erase, 0x34/0x36/0x37, check,
 * 0x11 — the session cmd/flash and the Lua flash.program run), on a UDS handle.
 *
 * bb_flash_open is bb_uds_open with the bootloader's default ids, 0x7B0 / 0x7B8. bb_flash_program
 * runs the session over handle `u` — the image's `n` bytes (a raw image gets its header here, a
 * BLBT .img goes as it is) — and fills *out; a failed step answers its UDS failure, named, and the
 * session's own verdicts BB_ERR_FLASH. It holds the handle for the whole transfer: another call
 * on it waits. bb_flash_cancel, from another thread, stops a flash in progress on `u` before its
 * next block, its waits ended within 20 ms, and the image is never checked or marked valid.
 *
 * bb_boot_sim starts a simulated blobly_emb bootloader on CAN row `row` of the run, to rehearse a
 * flash with no board: it hears requests on `tx` and answers on `rx` (the tester's ids, NULL for
 * 0x7B0 / 0x7B8), strict where a real one is — 0x29 verifies the proof against the dev tester key,
 * erase is refused before it, the check routine answers from the CRC the image header states.
 * Answers a handle; bb_boot_sim_stop stops it and says what it was asked. bb_stop stops it too (its
 * report is still bb_boot_sim_stop's), so none answers into the next run. */
int bb_flash_defaults(bb_flash_opts *opts);
int bb_flash_open(int row, const int64_t *tx, const int64_t *rx, bb_uds_target *out);
int bb_flash_program(int u, const uint8_t *image, int n, const bb_flash_opts *opts,
                     bb_flash_report *out);
int bb_flash_cancel(int u);
int bb_boot_sim(int row, const int64_t *tx, const int64_t *rx);
int bb_boot_sim_stop(int sim, bb_boot_report *out);
/* The CAN bridge (docs/wsl_bridge.md): on Windows, `canbridge` run inside a WSL distribution
 * carries that distribution's CAN interfaces to this process, as `bridge:<distribution>/<interface>`
 * rows. Opening such a row (bb_bus_open, bb_start) starts its bridge and waits for it; these calls
 * do it explicitly, as the GUI's Discover dialog does. A bridge is Windows-to-WSL: elsewhere there
 * are no distributions and bb_bridge_start is refused, saying so. Lists are one string, an entry per
 * line, into the caller's buffer as bb_message_name's. Every call but bb_bridge_stop may come from
 * any (attached) thread.
 *
 * bb_bridge_start launches the bridge (as root, so it can create vcan0/vcan1) unless it is
 * connected or starting, and returns once it is launched: bb_bridge_state follows it from there.
 * The `canbridge` it runs is bb_bridge_program's, else one on the distribution's PATH.
 * bb_bridge_stop disconnects a connected bridge, which ends it, and returns once it has gone (every
 * handle open on it fails); a bridge that is not connected, or a run that is started, is
 * BB_ERR_STATE, and a bridge whose connection was cut but did not end within 2 s BB_ERR_TIMEOUT. A bridge still starting cannot be stopped: it is reachable only once it dials in. */
int bb_wsl_distros(char *buf, int cap);           /* >= 0: the length; the installed distributions */
int bb_bridge_program(char *buf, int cap);        /* >= 0: the length of the path of the canbridge a
                                                     start runs (beside the library, then beside the
                                                     executable); "" when there is none */
int bb_bridge_start(const char *distro);
int bb_bridge_state(const char *distro, int *state, char *why, int cap); /* >= 0: the length of
                                                     the reason (failed only, "" otherwise);
                                                     *state an enum bb_bridge_state */
int bb_bridge_rows(const char *distro, char *buf, int cap); /* >= 0: the length; the connected
                                                     bridge's interfaces, "bridge:<distro>/vcan0" */
int bb_bridge_stop(const char *distro);
/* Bus metrics (bb_busload, bb_diagnostics above): from the thread that uses the handle. */
int bb_bus_load(int h, bb_busload *out);
int bb_bus_diagnostics(int h, bb_diagnostics *out);
/* Generators: the project's `senders:` in the run (blobly/headless generators.v), as the Lua
 * gen.* has them — every CAN row's, a disabled row's included, in project order, `g` 0 ..
 * bb_gen_count - 1. From bb_start until bb_stop (BB_ERR_STATE otherwise, and for a call a stop
 * overtook); any (attached) thread. Each generator has a loop of its own that holds its bus: a
 * cyclic one's starts with the run, any other's at its first fire or start.
 *
 * bb_gen_fire sends its current frame once and returns once the bus took it — generator g of run
 * `run` (bb_gen_run's number, 0 for whichever is started: BB_ERR_STATE when another run is, so a
 * host need hold no lock of its own across the wait for a stop and start not to move the index):
 * BB_ERR for a bus
 * that refused it (a listen-only row) or a generator with nothing to send on, BB_ERR_TIMEOUT when
 * its bus did not take it by until_ns (bb_now_ns's clock: an absolute deadline, so time spent
 * reaching the call counts; 0 or less, or past 5 s from now: 5 s from now; a first fire opens the
 * bus) — the message says whether it went out: a fire its loop had not taken by the deadline is
 * never sent, one it answered past it did go out. A stop that overtakes a fire is BB_ERR_STATE,
 * whatever became of the frame. bb_gen_start sends it on its
 * cycle from now — `cycle_ms`, or its own when 0 (refused when it has none) — and bb_gen_stop ends
 * that. bb_gen_cycle sets the cycle (1 .. 3600000 ms), from its next frame. bb_gen_set sends
 * `signal` at the static `value` from its next frame (its value source dropped), bb_gen_source
 * from the value source *w; a signal its message does not have (or whose payload does not hold
 * it), a raw frame's, a non-finite value
 * and a source that cannot be evaluated (an unknown type, a zero period or count) are refused. A
 * signal the generator did not list is added. */
int bb_gen_count(void);                                  /* >= 0: how many */
int bb_gen_find(const char *name);                       /* >= 0: the generator `name` names —
                                                            its name or "channel/name"; BB_ERR for
                                                            none, or one two answer to (then by
                                                            index) */
int bb_gen_info(int g, bb_generator *out);
int bb_gen_text(int g, int which, char *buf, int cap);   /* >= 0: the length; which is an enum
                                                            bb_gen_text */
int bb_gen_run(int64_t *run);                            /* the run's number: a fire names it */
int bb_gen_fire(int g, int64_t run, int64_t until_ns);
int bb_gen_start(int g, int cycle_ms);
int bb_gen_stop(int g);
int bb_gen_cycle(int g, int cycle_ms);
int bb_gen_set(int g, const char *signal, double value);
int bb_gen_source(int g, const char *signal, const bb_wave *w);

/* Replay and recording to a file (blobly/replay), as the Lua replay.start and record.start.
 *
 * bb_replay_start plays a recording onto CAN rows rows[0..n-1] of the run, on one clock, by
 * blobly/player: the ECU under test subtracted by DBC sender as each row's replay: block (or
 * opts->exclude) says, what *opts leaves to the rows their replay: blocks deciding. Refused with
 * BB_ERR where it would play something else than asked (no source, a recorded bus that does not
 * resolve, an exclusion no row's database declares, two rows on one recorded or live bus, nothing
 * left to play, rows disagreeing about a source, speed or loop *opts does not settle);
 * BB_ERR_STATE before bb_start. Answers a handle. bb_replay_pause, _seek, _speed and _loop are
 * applied before they return (bb_replay_status then says so); bb_replay_wait waits at most
 * timeout_ms (negative: for ever) for a non-looping replay to run out or the replay to be stopped:
 * 0 when it did, BB_NONE when not. bb_replay_stop stops it, lets its buses go and reads its last
 * status; the handle stays readable (status, error, notes) and refuses a control. bb_stop stops
 * every replay too, so none plays into the next run. Start and stop are state calls; the rest may
 * come from any (attached) thread.
 *
 * bb_record_start writes what rows rows[0..n-1] carry to the candump .log at `path` (created or
 * truncated), a line per frame as it is read: `(t) <row name> <id>#<data> T` for a frame this
 * process sent, R for the rest, t the host's monotonic clock in seconds. Two rows on one wire are
 * refused (each frame would be written twice), and so are two rows of one name (their lines could
 * not be told apart); an existing file is truncated only once the rows' buses are open.
 * bb_record_stop ends it and fills *out, the handle staying readable; BB_ERR when a write or a
 * receive failed on the way, or a reader or a send did not finish within 2 s (the file keeps what
 * was written before), *out still filled. bb_stop stops every recording too (what went wrong with
 * one is then its bb_record_stop's to say: the error is kept on its handle), and a replay or a
 * recording still letting go of its buses holds the process as a run's loop does (BB_RELEASING,
 * bb_wait_released). */
int bb_replay_defaults(bb_replay_opts *opts);
int bb_replay_start(const int *rows, int n, const bb_replay_opts *opts);
int bb_replay_notes(int r, char *buf, int cap);   /* >= 0: the length; what the plan kept and
                                                     withheld per row, a line each */
int bb_replay_pause(int r, int paused);           /* 1 pause, 0 resume */
int bb_replay_seek(int r, double position_s);
int bb_replay_speed(int r, double speed);
int bb_replay_loop(int r, int on);
int bb_replay_status(int r, bb_replay_info *out);
int bb_replay_error(int r, char *buf, int cap);   /* >= 0: the length; the first failed send */
int bb_replay_wait(int r, int timeout_ms);
int bb_replay_stop(int r, bb_replay_info *out);
int bb_record_start(const int *rows, int n, const char *path);
int bb_record_counts(int h, bb_record_report *out);
int bb_record_stop(int h, bb_record_report *out);
#endif /* BB_FROM_V */

/* Raw ISO-TP, UDS timing and the DoIP retarget (isotp.v, udstiming.v).
 *
 * A raw ISO-TP channel (ISO 15765-2) carries whole messages on a CAN row's request / response id
 * pair with no UDS on top — a proprietary protocol over ISO-TP, or a malformed UDS request and the
 * bytes that come back: the engine's software ISO-TP (blobly/isotp), the channel a UDS handle rides,
 * opened by the same rule (blobly/udsconn) on a CAN row of the run (BB_ERR_STATE before bb_start).
 * Both ids are given (no default pair), either past 0x7FF makes both 29-bit, and `out` (unless NULL)
 * gets them. Classic addressing in 8-byte frames (sent FD on a row the project declares CAN-FD): a
 * message is 1 .. 4095 bytes. As a receiver it asks for no pacing (Flow Control CTS, block size 0,
 * STmin 0); as a sender it honours the receiver's.
 * Handles as a UDS handle's: one thread uses one at a time, bb_isotp_close may come from another and
 * ends a send or receive in progress there (BB_ERR_HANDLE) within 20 ms of the wait it is in; a
 * handle outlives bb_stop. Open one handle per id pair: two on one rx (a UDS handle's included) each
 * answer a First Frame with a Flow Control of their own.
 *
 * bb_isotp_send returns once the message is on the wire: a Single Frame at once, a longer one after
 * the receiver's Flow Control, each awaited for 1000 ms (N_Bs) and the transfer 120 s in all —
 * BB_ERR_TIMEOUT when none came, BB_ERR for a message it cannot carry (empty, past 4095 bytes) or a
 * listen-only row, BB_ERR_CARRIER for the bus or the transfer failing (the receiver's overflow, too
 * many waits). bb_isotp_recv waits at most timeout_ms (0: one look at what is queued; less than 0 is
 * refused) for the next whole message on rx and answers its length, its bytes into the buffer as
 * bb_uds_data's (bb_isotp_data copies them again, whole, until the next receive); BB_ERR_TIMEOUT when
 * nothing whole came — a transfer begun is kept, and the next receive goes on with it, given up after
 * 1000 ms with no Consecutive Frame (N_Cr: BB_ERR_CARRIER, as for a frame lost or not ISO-TP).
 *
 * A UDS handle's timing (blobly/uds Client) is the waits above bb_uds_open's: the first answer's
 * (timeout_ms, 1000), the ECU's P2* after each responsePending (p2_star_ms, 5000 until a 0x10 answer
 * names one) plus margin_ms (1000), and one request's whole allowance from its send
 * (pending_budget_ms, 120000). bb_uds_get_timing reads them as they stand (a 0x10 answer adopts its
 * P2*, and lengthens timeout_ms where its P2 needs more); bb_uds_set_wait states one of them, `which`
 * an enum bb_uds_wait, from the next request on — refused with BB_ERR, nothing changed, for
 * timeout_ms or pending_budget_ms outside 1 .. 3600000, or p2_star_ms or margin_ms outside
 * 0 .. 3600000; bb_uds_check_wait answers the same of no handle (any thread), so a host refuses a
 * wait before it opens a connection to state it on. They hold across the library's own reopen of a lost DoIP connection (P2* only where
 * it loosens the new one's). Every call above is then bounded by them in place of the 1000 / P2* +
 * 1000 / 120 s bb_uds_open states.
 *
 * bb_uds_retarget moves a DoIP handle's requests, and the answers it takes, to logical address
 * *address (0 .. 0xFFFF; NULL: the row's ecu_address): a node behind the gateway the row's entity is
 * (ISO 13400-2), on the one connection, so what the tester unlocked on the gateway there holds for
 * the node. The target holds across a reopen of a lost connection, whose new routing activation
 * carries no unlock: a gateway that routes only an unlocked tester refuses the node's requests again
 * (a negative acknowledgement, BB_ERR_CARRIER) until it is unlocked on the new one. Another target is
 * another ECU: the handle's waits go back to what was stated with bb_uds_set_wait (the rest to
 * bb_uds_open's), and the snapshot DID sizes it learned are forgotten (bb_uds_did_size's are kept).
 * On a connection
 * that replaces another (bb_uds_replaces, or the library's reopen), a 0x27 key goes only to a target
 * whose seed of its level was answered on it. BB_ERR on a CAN handle, whose target is its ids. */
typedef struct bb_uds_timing {
	int32_t timeout_ms;
	int32_t p2_star_ms;
	int32_t margin_ms;
	int32_t pending_budget_ms;
} bb_uds_timing;
enum bb_uds_wait {
	BB_WAIT_TIMEOUT = 0,         /* timeout_ms */
	BB_WAIT_P2_STAR = 1,         /* p2_star_ms */
	BB_WAIT_MARGIN = 2,          /* margin_ms */
	BB_WAIT_PENDING_BUDGET = 3   /* pending_budget_ms */
};
#ifndef BB_FROM_V
int bb_isotp_open(int row, int64_t tx, int64_t rx, bb_uds_target *out); /* >= 0: the handle */
int bb_isotp_send(int h, const uint8_t *data, int n);
int bb_isotp_recv(int h, int timeout_ms, uint8_t *buf, int cap);        /* >= 0: the length */
int bb_isotp_data(int h, uint8_t *buf, int cap);
int bb_isotp_close(int h);
int bb_uds_get_timing(int u, bb_uds_timing *out);
int bb_uds_set_wait(int u, int which, int ms);
int bb_uds_check_wait(int which, int ms);
int bb_uds_retarget(int u, const int64_t *address);
/* The system model (docs/scripting.md, "Nodes"): blobly_emb's system.toml beside the project (or
 * beside one of its databases, or in its folder's parent) and each node's ecu.toml, as the RUN read
 * them — the description its simulated diagnostic servers answer by — from bb_start until bb_stop
 * (BB_ERR_STATE otherwise). A tester reaches a node by its name, the model supplying the row and the
 * ids, and reads and writes its DIDs by name, through the node's layout. Every call here but
 * bb_uds_write_described only reads, and may come from any (attached) thread. Strings go into the
 * caller's buffer as bb_message_name's. `n` is 0 .. bb_node_count - 1, `d` 0 .. its dids - 1.
 *
 * bb_node_reach is the target a UDS handle opens on: the node's one target, or the one on `row`
 * (-1: wherever it is); refused, saying how the node is reached, when that is no row of the run,
 * and when it is several and none is named. A DID's value is its parts' texts (bb_did_part's kind:
 * an integer in decimal, true / false, a text, bytes in hex): bb_did_text reads part p of a value
 * read with bb_uds_read_did — BB_ERR_UNDECODABLE when the bytes are not the size the description
 * lays out — and bb_uds_write_described writes the k texts of every part, encoded by the same
 * layout: refused (BB_ERR, nothing sent) for a text the layout does not hold or a DID with no write
 * gate; BB_ERR_GATED, nothing sent and *needs filled, when the handle's connection has not
 * established what the write gate needs — the session (a positive 0x10 on it) and the level (a
 * granted 0x27), as its own exchanges say. It never switches or unlocks itself. */
int bb_system_path(char *buf, int cap);              /* >= 0: the length of the system.toml's path;
                                                        "" when none describes the project */
int bb_node_count(void);                             /* >= 0 */
int bb_node_info(int n, bb_node *out);
int bb_node_name(int n, char *buf, int cap);         /* >= 0: the length */
int bb_node_problem(int n, char *buf, int cap);      /* >= 0: why its ecu.toml was not read, "" */
int bb_node_target(int n, int k, bb_reach *out);
int bb_node_reach(int n, int row, bb_reach *out);
int bb_node_fault(int n, int k, uint32_t *dtc, char *buf, int cap); /* >= 0: the fault's name's
                                                        length; *dtc its 24-bit DTC */
int bb_did_info(int n, int d, bb_did *out);
int bb_did_name(int n, int d, char *buf, int cap);   /* >= 0: the length; "" for a DID of no name */
int bb_did_session(int n, int d, int write, int k, char *buf, int cap); /* the k-th session of its
                                                        read (write 0) or write gate, as named */
int bb_did_part(int n, int d, int p, int *kind, char *buf, int cap); /* >= 0: the length of its
                                                        label; *kind an enum bb_part_kind */
int bb_did_hint(int n, int d, int p, char *buf, int cap); /* what the part accepts: "u16 0..360" */
int bb_did_text(int n, int d, const uint8_t *data, int len, int p, char *buf, int cap); /* p -1:
                                                        the value checked alone, answering "" */
int bb_uds_write_described(int u, int n, int d, const char *const *texts, int k,
                           bb_write_needs *needs);
#endif /* BB_FROM_V */

/* J1939 on a row's frames (cmd/libblobly/j1939.v, blobly/j1939): the transport protocol (BAM and
 * RTS/CTS) rejoined and the address directory, read from the frames a bus handle reads — a frame
 * is still consumed once, by whoever reads it, and what the handle sends is never in it. A
 * LISTENER: nothing is sent, no CTS, no acknowledgement, no address claim.
 *
 * bb_j1939_attach binds handle h to row `row` of the run (BB_ERR_STATE before bb_start): every
 * frame bb_bus_recv reads on it from then on is fed to the listener, and a receive that finds
 * nothing queued (BB_NONE) times the stalled transfers out (T1 750 ms for a BAM, T3 1250 ms for a
 * connection). Nothing decides a bus IS J1939, so it is opt-in: with force 0 it attaches only where
 * the row's wire says so — a row on it ticked `j1939:`, or with a database that declares J1939
 * (VFrameFormat J1939PG), the GUI's per-wire gate — and answers 0 elsewhere; with force 1 it
 * attaches on any CAN row. 1: listening. Attaching a handle already listening in this run keeps
 * what it has.
 *
 * bb_j1939_take_message takes the oldest completed message (BB_NONE when none waits): its parameter
 * group, addresses and data, and its decode through the row's merged databases by the trace's rule
 * (candb.pgn_message_in: the message at exactly that PGN and source address, else by PGN alone,
 * nothing where definitions disagree — `note` says why) — `message` its position (bb_message_info),
 * values[k] / active[k] its signals as bb_decode gives them (cap at least its signal count, else
 * BB_ERR with the message kept). bb_j1939_take_fault takes the oldest fault. A listener keeps 1024 of
 * each untaken; past that the oldest is dropped, and bb_j1939_dropped counts them.
 * bb_j1939_address_count / bb_j1939_address_info are the directory as it stands, by address: who
 * claimed which source address with which NAME, contention settled by J1939-81 (the lower NAME
 * keeps it), a Cannot Claim releasing it. All on the thread that uses the handle. */
#define BB_J1939_MAX 1785      /* the longest transport-protocol message, in bytes */
#define BB_J1939_TEXT 256      /* bb_j1939_fault's texts and bb_j1939_message.note, NUL included */
typedef struct bb_j1939_message {
	uint32_t pgn;
	uint8_t  sa;
	uint8_t  da;          /* 0xFF for a BAM */
	uint8_t  priority;    /* the announcement's */
	uint8_t  bam;         /* 1 a BAM, 0 an RTS/CTS connection */
	int32_t  len;
	int32_t  message;     /* its position in the row's databases (bb_message_info), -1 none */
	int64_t  t_start_ns;  /* when the announcement and the last packet were read (bb_now_ns) */
	int64_t  t_end_ns;
	uint8_t  data[BB_J1939_MAX];
	char     note[BB_J1939_TEXT]; /* why it is not decoded where definitions disagree, else "" */
} bb_j1939_message;
/* What went wrong with a transfer (j1939.FaultKind). */
enum bb_j1939_fault_kind {
	BB_J1939_ORPHAN = 0,     /* a data frame with no transfer to belong to */
	BB_J1939_SEQUENCE = 1,   /* a packet out of sequence (dropped or repeated): transfer abandoned */
	BB_J1939_RESTARTED = 2,  /* a new announcement on a pair still mid-transfer */
	BB_J1939_ABORTED = 3,    /* a Connection Abort, its reason in the detail */
	BB_J1939_TIMEOUT = 4,    /* nothing within T1 / T3 */
	BB_J1939_MALFORMED = 5,  /* a control frame J1939-21 does not permit */
	BB_J1939_OVERFLOW = 6,   /* more transfers open than the listener keeps (64) */
	BB_J1939_PADDING = 7,    /* the last packet not padded with 0xFF (the message is kept) */
	BB_J1939_OFF_SPEC = 8,   /* a reserved control byte not 0xFF (the frame is read as ever) */
	BB_J1939_TRUNCATED = 9   /* still open when the observation ended */
};
typedef struct bb_j1939_fault {
	int32_t  kind;        /* an enum bb_j1939_fault_kind */
	uint8_t  sa;
	uint8_t  da;
	uint8_t  announced;   /* the transfer announced its parameter group: pgn is it */
	uint32_t pgn;
	char     detail[BB_J1939_TEXT];
	char     text[BB_J1939_TEXT]; /* the whole fault in words, the line the GUI's Log writes */
} bb_j1939_fault;
/* A held source address and the NAME that claimed it (j1939.Name, J1939-81's fields). */
typedef struct bb_j1939_address {
	uint8_t  sa;
	uint64_t name;        /* the 64-bit NAME as claimed */
	uint32_t identity;
	uint16_t manufacturer;
	uint8_t  ecu_instance;
	uint8_t  function_instance;
	uint8_t  function;
	uint8_t  vehicle_system;
	uint8_t  vehicle_system_instance;
	uint8_t  industry_group;
	uint8_t  arbitrary_address_capable;
	int64_t  t_ns;        /* when the claim was read (bb_now_ns) */
} bb_j1939_address;
#ifndef BB_FROM_V
int bb_j1939_attach(int h, int row, int force);    /* 1 listening, 0 not (force 0, a row that
                                                      does not say J1939) */
int bb_j1939_take_message(int h, bb_j1939_message *out, double *values, uint8_t *active, int cap);
int bb_j1939_take_fault(int h, bb_j1939_fault *out);
int bb_j1939_dropped(int h);                       /* >= 0 */
int bb_j1939_address_count(int h);                 /* >= 0 */
int bb_j1939_address_info(int h, int k, bb_j1939_address *out);
int bb_j1939_function_name(int function, char *buf, int cap); /* >= 0: the length of the global
                                                      function's name; "" for one J1939 names
                                                      per industry, or past the 32 global ones */
#endif /* BB_FROM_V */

#ifdef __cplusplus
}
#endif

#endif /* BLOBLY_BB_H */
