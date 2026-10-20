/* bb.h — the C ABI of libblobly, the Blobly Net engine as a shared library (cmd/libblobly).
 *
 * THE ONE STATEMENT OF THE ABI: V compiles this header in (cmd/libblobly/lib.v) and every host
 * — the C smoke, the ctypes smoke, a Python package — reads it. What the two sides disagree on
 * is a crash, so nothing about a call lives anywhere else.
 *
 * Conventions:
 *   - every call returns int: 0 on success, < 0 on error, and bb_last_error() names the last
 *     error (the message belongs to the library; copy it if you keep it). Calls that have a
 *     non-error "nothing" answer return > 0 for it (bb_bus_recv: 1 = no frame in time).
 *     bb_bus_open and bb_bus_health return their value when >= 0.
 *   - call bb_init() once before anything else, from the thread that will drive the library.
 *     The V runtime initialises itself when the library is loaded (a constructor); bb_init is
 *     where a host-side requirement would go, and a host that calls it is not broken by one.
 *   - a thread the HOST created calls bb_thread_attach() before its first other call and
 *     bb_thread_detach() before it ends: the library's collector scans the stacks of the threads
 *     it knows, and an allocation on an unknown one aborts the process at the next collection
 *     ("Collecting from unknown thread"). The thread that loaded the library needs neither;
 *     attaching it again is harmless.
 *   - ONE HOST THREAD drives the library's STATE in this version: open, close, load, start and
 *     stop are not synchronised against each other. Send and recv on a handle may run on an
 *     attached thread of their own. A frame received is copied into the caller's bb_frame;
 *     nothing handed out points into the library except the strings, which stay valid until the
 *     next call that replaces them (bb_last_error, bb_channel_*).
 *   - the engine's progress and warnings go to the process's stdout and stderr, as the headless
 *     runner's do.
 */
#ifndef BLOBLY_BB_H
#define BLOBLY_BB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A CAN frame on the wire. `len` is the payload length (0..8 classic, up to 64 with fd);
 * `ext` a 29-bit identifier; `fd`/`brs` CAN-FD and its bit-rate switch. On a send, fd and brs
 * unset mean "not stated": the frame takes the wire's declared format. */
typedef struct bb_frame {
	uint32_t id;
	uint8_t  len;
	uint8_t  ext;
	uint8_t  fd;
	uint8_t  brs;
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

/* Error codes. The message (bb_last_error) says what; the code says which kind. */
#define BB_ERR         (-1)  /* refused, with a reason in bb_last_error */
#define BB_ERR_HANDLE  (-2)  /* no such bus handle, or a closed one */
#define BB_ERR_STATE   (-3)  /* nothing loaded / not started / already started */

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
 * the run and frees the process for the next start. */
int bb_load(const char *project_path);
int bb_start(void);
int bb_stop(void);

/* The loaded project's ENABLED rows, in project order. */
int         bb_channel_count(void);
const char *bb_channel_name(int i);
const char *bb_channel_iface(int i);   /* what bb_bus_open takes for this row */

/* A bus handle of the host's own on an interface ("inproc:CAN1", "vcan0", "pcan:PCAN_USBBUS1@500000"). */
int bb_bus_open(const char *iface);                          /* >= 0: the handle */
int bb_bus_send(int h, const bb_frame *f);
int bb_bus_recv(int h, int timeout_ms, bb_frame *out);       /* 0: a frame; 1: none in time */
int bb_bus_health(int h);                                    /* >= 0: an enum bb_health */
int bb_bus_close(int h);
#endif /* BB_FROM_V */

#ifdef __cplusplus
}
#endif

#endif /* BLOBLY_BB_H */
