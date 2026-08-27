/* pcan_shim.h — flat C wrappers over PEAK's PCANBasic.dll, resolved at RUNTIME via
 * LoadLibrary/GetProcAddress so we need NO SDK, NO import .lib, and work with mingw
 * OR MSVC. Same pattern as socketcan_shim.h. Windows-only (included only by
 * pcan_windows.v). The DLL ships with the free PEAK driver; if it's absent
 * ct_pcan_load() returns non-zero and the V backend surfaces a clean error.
 *
 * x64 note: Win64 has a single calling convention, so __stdcall is a no-op there
 * (it matters only on 32-bit, which we don't target).
 */
#ifndef CT_PCAN_SHIM_H
#define CT_PCAN_SHIM_H

#include <windows.h>
#include <stdint.h>

/* PCANBasic message-type flags + status codes we care about. */
#define CT_PCAN_MSG_STANDARD 0x00
#define CT_PCAN_MSG_RTR      0x01
#define CT_PCAN_MSG_EXTENDED 0x02
#define CT_PCAN_MSG_STATUS   0x80
/* CAN-FD message flags. PCANBasic carries them in the same MSGTYPE byte the classic flags use. */
#define CT_PCAN_MSG_FD       0x04
#define CT_PCAN_MSG_BRS      0x08
#define CT_PCAN_MSG_ESI      0x10
#define CT_PCAN_ERROR_OK        0x00000u
#define CT_PCAN_ERROR_QRCVEMPTY 0x00020u

typedef struct {
	uint32_t ID;       /* 11/29-bit id */
	uint8_t  MSGTYPE;  /* CT_PCAN_MSG_* bit flags */
	uint8_t  LEN;      /* 0..8 */
	uint8_t  DATA[8];
} CT_TPCANMsg;

/* The FD message. Two differences from CT_TPCANMsg that matter and are easy to miss:
 * DLC is a DLC *code* (0..15) rather than a byte count, and the payload is 64 bytes. Treating
 * the code as a length is how a 12-byte frame becomes a 12-length DLC meaning 24 bytes. */
typedef struct {
	uint32_t ID;
	uint8_t  MSGTYPE;
	uint8_t  DLC;      /* DLC CODE 0..15, not a byte count */
	uint8_t  DATA[64];
} CT_TPCANMsgFD;

typedef uint32_t (__stdcall *ct_pInit)(uint16_t, uint16_t, uint8_t, uint32_t, uint16_t);
/* CAN_InitializeFD takes the bitrate as a STRING of register values -- see pcan_names.v. */
typedef uint32_t (__stdcall *ct_pInitFD)(uint16_t, const char *);
typedef uint32_t (__stdcall *ct_pWriteFD)(uint16_t, CT_TPCANMsgFD *);
typedef uint32_t (__stdcall *ct_pReadFD)(uint16_t, CT_TPCANMsgFD *, void *);
typedef uint32_t (__stdcall *ct_pUninit)(uint16_t);
typedef uint32_t (__stdcall *ct_pWrite)(uint16_t, CT_TPCANMsg *);
typedef uint32_t (__stdcall *ct_pRead)(uint16_t, CT_TPCANMsg *, void *);

typedef uint32_t (__stdcall *ct_pGetValue)(uint16_t, uint8_t, void *, uint32_t);
typedef uint32_t (__stdcall *ct_pGetStatus)(uint16_t);

static ct_pInit     ct_fn_init;
static ct_pUninit   ct_fn_uninit;
static ct_pWrite    ct_fn_write;
static ct_pRead     ct_fn_read;
static ct_pGetValue ct_fn_getvalue; /* CAN_GetValue — discovery only, optional */
static ct_pGetStatus ct_fn_getstatus; /* CAN_GetStatus — bus health, optional */
/* Absent on a pre-FD PCANBasic. Their absence is what "this driver cannot do FD" looks like. */
static ct_pInitFD   ct_fn_initfd;
static ct_pWriteFD  ct_fn_writefd;
static ct_pReadFD   ct_fn_readfd;

/* Load the DLL + resolve the four entry points. 0 ok, -1 DLL missing, -2 symbol missing. */
static int ct_pcan_load(void) {
	HMODULE h = LoadLibraryA("PCANBasic.dll");
	if (!h) return -1;
	ct_fn_init   = (ct_pInit)(void *)GetProcAddress(h, "CAN_Initialize");
	ct_fn_uninit = (ct_pUninit)(void *)GetProcAddress(h, "CAN_Uninitialize");
	ct_fn_write  = (ct_pWrite)(void *)GetProcAddress(h, "CAN_Write");
	ct_fn_read   = (ct_pRead)(void *)GetProcAddress(h, "CAN_Read");
	ct_fn_initfd  = (ct_pInitFD)(void *)GetProcAddress(h, "CAN_InitializeFD");
	ct_fn_writefd = (ct_pWriteFD)(void *)GetProcAddress(h, "CAN_WriteFD");
	ct_fn_readfd  = (ct_pReadFD)(void *)GetProcAddress(h, "CAN_ReadFD");
	ct_fn_getvalue = (ct_pGetValue)(void *)GetProcAddress(h, "CAN_GetValue");
	ct_fn_getstatus = (ct_pGetStatus)(void *)GetProcAddress(h, "CAN_GetStatus");
	if (!ct_fn_init || !ct_fn_uninit || !ct_fn_write || !ct_fn_read) return -2;
	return 0;
}

/* Condition of a PCAN channel handle (param PCAN_CHANNEL_CONDITION = 0x0D; queryable on
 * an UNinitialized channel): returns 0 unavailable, 0x01 available, 0x04 occupied (bits),
 * or -1 if it can't be queried. Discovery probes the fixed USB handles (PCAN_USBBUS1 =
 * 0x51, …). NOTE: 0x07 is PCAN_BUSOFF_AUTORESET, not the condition — easy to get wrong. */
static int ct_pcan_condition(uint16_t handle) {
	uint32_t cond = 0;
	if (ct_pcan_load() != 0 || !ct_fn_getvalue) return -1;
	if (ct_fn_getvalue(handle, 0x0D, &cond, 4) != CT_PCAN_ERROR_OK) return -1;
	return (int)cond;
}

/* CAN_Initialize(channel, baud, hwtype=0, ioport=0, irq=0) — 0 on success. */
static uint32_t ct_pcan_init(uint16_t ch, uint16_t baud) {
	return ct_fn_init(ch, baud, 0, 0, 0);
}

static uint32_t ct_pcan_uninit(uint16_t ch) {
	return ct_fn_uninit(ch);
}

static uint32_t ct_pcan_write(uint16_t ch, uint32_t id, uint8_t msgtype, uint8_t len, const uint8_t *data) {
	CT_TPCANMsg m;
	int i;
	if (len > 8) len = 8;
	m.ID = id;
	m.MSGTYPE = msgtype;
	m.LEN = len;
	for (i = 0; i < 8; i++) m.DATA[i] = (i < len) ? data[i] : 0;
	return ct_fn_write(ch, &m);
}

/* Read one message. Returns PCANBasic's status word VERBATIM; the out params carry whatever
 * the call left in the message struct.
 *
 * Deciding what that word means is the CALLER's job (transport.pcan_read_verdict), for two
 * reasons. It is testable in V and untestable here — this file only compiles on Windows, so a
 * test of it would never run in CI. And it was WRONG here: this function used to report any
 * status that was neither OK nor QRCVEMPTY as a failed read, but CAN_Read ORs the fault ladder
 * (BUSLIGHT/BUSHEAVY/BUSOFF/BUSPASSIVE) into its return, and the caller answers a failed read
 * by disabling the whole wire. A channel transmitting into a disconnected bus reports BUSHEAVY
 * within half a second, so it killed its own reader and the trace simply stopped. */
static uint32_t ct_pcan_read(uint16_t ch, uint32_t *id, uint8_t *msgtype, uint8_t *len, uint8_t *data) {
	CT_TPCANMsg m = {0}; /* zeroed: on an empty read the vendor leaves this untouched */
	uint32_t st = ct_fn_read(ch, &m, NULL);
	int i;
	*id = m.ID;
	*msgtype = m.MSGTYPE;
	*len = m.LEN;
	for (i = 0; i < 8; i++) data[i] = m.DATA[i];
	return st;
}

/* Bus status word of an initialized channel (PCAN_ERROR_* bits: BUSLIGHT 0x04, BUSHEAVY
 * 0x08, BUSOFF 0x10, BUSPASSIVE 0x40000). 0 = error-active and healthy. Returns the raw
 * status; 0xFFFFFFFF when the symbol is absent (older DLL) — the caller reads that as
 * "cannot say", never as a state. */
/* ---- CAN-FD -------------------------------------------------------------------------------
 *
 * Present only on a PCANBasic new enough to export them. ct_pcan_has_fd() is how the V side asks,
 * so "your driver is too old" is a sentence somebody reads rather than a crash.
 */
static int ct_pcan_has_fd(void) {
	return (ct_fn_initfd && ct_fn_writefd && ct_fn_readfd) ? 1 : 0;
}

/* CAN_InitializeFD(channel, "f_clock=...,nom_brp=...,...") — 0 on success. */
static uint32_t ct_pcan_init_fd(uint16_t ch, const char *bitrate) {
	if (!ct_fn_initfd) return 0xFFFFFFFFu;
	return ct_fn_initfd(ch, bitrate);
}

/* `dlc` is the DLC CODE, and `len` the byte count it stands for: the caller has both because the
 * conversion lives in V beside fd_lengths, which is the one place this repo states it. */
static uint32_t ct_pcan_write_fd(uint16_t ch, uint32_t id, uint8_t msgtype, uint8_t dlc,
                                 uint8_t len, const uint8_t *data) {
	CT_TPCANMsgFD m;
	int i;
	if (!ct_fn_writefd) return 0xFFFFFFFFu;
	m.ID = id;
	m.MSGTYPE = msgtype;
	m.DLC = dlc;
	if (len > 64) len = 64;
	for (i = 0; i < 64; i++) m.DATA[i] = (i < len) ? data[i] : 0;
	return ct_fn_writefd(ch, &m);
}

/* Reads one FD message. Returns the raw status; the caller reads QRCVEMPTY as "nothing waiting"
 * exactly as the classic path does, and gets the DLC CODE out to convert in V.
 *
 * A 64-BYTE BUFFER ALWAYS, whichever the frame turns out to be: an FD-opened channel carries
 * classic frames too, and a short buffer here is the difference between a 64-byte frame arriving
 * and smashing the stack. */
static uint32_t ct_pcan_read_fd(uint16_t ch, uint32_t *id, uint8_t *msgtype, uint8_t *dlc,
                                uint8_t *data) {
	CT_TPCANMsgFD m = {0}; /* zeroed: on an empty read the vendor leaves this untouched */
	uint32_t st;
	int i;
	if (!ct_fn_readfd) return 0xFFFFFFFFu;
	/* COPIED OUT WHATEVER THE STATUS SAYS, exactly as the classic reader does, and for the reason
	 * pcan_read_verdict exists: CAN_Read ORs the bus fault ladder into the status, so BUSLIGHT or
	 * BUSHEAVY comes back alongside a perfectly good frame. Returning early on a non-zero status
	 * threw that frame away and handed the caller a zeroed one instead -- and the ladder appears
	 * within half a second of transmitting into a disconnected bus, so it is the state a bench in
	 * trouble is actually in (self-review). The verdict is V's to make; this only reports. */
	st = ct_fn_readfd(ch, &m, NULL);
	*id = m.ID;
	*msgtype = m.MSGTYPE;
	*dlc = m.DLC;
	for (i = 0; i < 64; i++) data[i] = m.DATA[i];
	return st;
}

static uint32_t ct_pcan_status(uint16_t ch) {
	if (!ct_fn_getstatus) return 0xFFFFFFFFu;
	return ct_fn_getstatus(ch);
}

#endif /* CT_PCAN_SHIM_H */
