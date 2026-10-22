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
 *     bb_bus_open, bb_bus_health and the bb_channel_* enums return their value when >= 0.
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
 *     library except the strings, which stay valid until the next call that replaces them
 *     (bb_last_error, bb_channel_*).
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

/* Error codes. The message (bb_last_error) says what; the code says which kind. */
#define BB_ERR         (-1)  /* refused, with a reason in bb_last_error */
#define BB_ERR_HANDLE  (-2)  /* no such bus handle, or a closed one */
#define BB_ERR_STATE   (-3)  /* nothing loaded / not started / already started / still releasing */

/* Answers that are neither success nor an error. */
#define BB_NONE        1     /* bb_bus_recv: no frame in time */
#define BB_SPENT       2     /* bb_bus_recv with timeout 0: no frame yet, but the look stopped at
                                its bound with records still queued — look again at once rather
                                than sleeping (transport.look_was_spent) */
#define BB_RELEASING   3     /* bb_stop: the run is stopped, but a loop outlived the stop's bound
                                and is still letting go of its wires; bb_start refuses with
                                BB_ERR_STATE until bb_wait_released says it is done */

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
#endif /* BB_FROM_V */

#ifdef __cplusplus
}
#endif

#endif /* BLOBLY_BB_H */
