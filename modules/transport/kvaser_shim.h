/* kvaser_shim.h — flat C wrappers over Kvaser's canlib32.dll, resolved at RUNTIME
 * via LoadLibrary/GetProcAddress (no SDK, no import .lib; mingw or MSVC). Same
 * pattern as socketcan_shim.h / pcan_shim.h. Windows-only (included only by
 * kvaser_windows.v). canlib32.dll ships with the free Kvaser drivers.
 *
 * Win64 LLP64: `long`/`unsigned long` are 32-bit — we use int32_t/uint32_t to match
 * canlib's `long id` / `unsigned long timeout`. canStatus: 0 == canOK, negatives
 * are errors; canERR_NOMSG == -2 (no message within timeout).
 */
#ifndef CT_KVASER_SHIM_H
#define CT_KVASER_SHIM_H

#include <windows.h>
#include <stdint.h>

/* message flags (read/write) + open flags we use */
#define CT_KV_MSG_RTR          0x0001
#define CT_KV_MSG_STD          0x0002
#define CT_KV_MSG_EXT          0x0004
#define CT_KV_MSG_ERROR_FRAME  0x0020
#define CT_KV_OPEN_ACCEPT_VIRTUAL 0x0020
#define CT_KV_OPEN_CAN_FD      0x0400
/* canWrite/canReadWait CAN-FD flags. canlib carries them in the high half of the same
 * word the classic flags use, so one flags argument says both. */
#define CT_KV_FDMSG_FDF        0x010000
#define CT_KV_FDMSG_BRS        0x020000
#define CT_KV_FDMSG_ESI        0x040000
#define CT_KV_ERR_NOMSG        (-2)

typedef void    (__stdcall *ct_kvInitLib)(void);
typedef int     (__stdcall *ct_kvOpen)(int, int);
typedef int     (__stdcall *ct_kvSetBus)(int, int32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
/* canSetBusParamsFd sets the DATA phase; canSetBusParams goes on setting arbitration.
 * OPTIONAL: a canlib older than the FD API has no such symbol, and the caller is told that
 * rather than finding out through a null call. */
typedef int     (__stdcall *ct_kvSetBusFd)(int, int32_t, uint32_t, uint32_t, uint32_t);
/* canSetBusOutputControl picks what the TRANSCEIVER does, which is a different question from
 * whether this process transmits. canDRIVER_SILENT listens without acknowledging; NORMAL is the
 * ordinary node. canlib requires the channel to be bus-OFF when this is set. */
typedef int     (__stdcall *ct_kvSetOutCtrl)(int, uint32_t);
typedef int     (__stdcall *ct_kvBusOn)(int);
typedef int     (__stdcall *ct_kvBusOff)(int);
typedef int     (__stdcall *ct_kvWrite)(int, int32_t, void *, uint32_t, uint32_t);
typedef int     (__stdcall *ct_kvReadWait)(int, int32_t *, void *, uint32_t *, uint32_t *, uint32_t *, uint32_t);
typedef int     (__stdcall *ct_kvClose)(int);

static ct_kvInitLib  ct_kv_initlib;
static ct_kvOpen     ct_kv_open;
static ct_kvSetBus   ct_kv_setbus;
static ct_kvSetBusFd ct_kv_setbusfd;
static ct_kvSetOutCtrl ct_kv_setoutctrl; /* canSetBusOutputControl — optional on ancient canlib */
static ct_kvBusOn    ct_kv_buson;
static ct_kvBusOff   ct_kv_busoff;
static ct_kvWrite    ct_kv_write;
static ct_kvReadWait ct_kv_readwait;
static ct_kvClose    ct_kv_close;

/* enumeration (optional — used for discovery, not I/O; older canlib may lack them) */
typedef int (__stdcall *ct_kvNumChan)(int *);
typedef int (__stdcall *ct_kvChanData)(int, int, void *, size_t);
static ct_kvNumChan  ct_kv_numchan;
static ct_kvChanData ct_kv_chandata;

/* bus health (optional): canReadStatus fills canSTAT_* flags — ERROR_PASSIVE 0x01,
 * BUS_OFF 0x02, ERROR_WARNING 0x04, ERROR_ACTIVE 0x08 (canstat.h; TX_PENDING 0x10,
 * RESERVED_1 0x40 carry no ladder meaning). This table once had PASSIVE/BUS_OFF swapped
 * and a 0x40 warning that does not exist — the decode AND its pinned test live in
 * modules/transport/health.v; read the vendor header, not this comment, before touching
 * either (codex #143 r2 caught this comment still carrying the swap the decoder shed). */
typedef int (__stdcall *ct_kvReadStatus)(int, uint32_t *);
static ct_kvReadStatus ct_kv_readstatus;

/* 0 ok, -1 DLL missing, -2 a symbol missing. */
static int ct_kvaser_load(void) {
	HMODULE h = LoadLibraryA("canlib32.dll");
	if (!h) return -1;
	ct_kv_initlib  = (ct_kvInitLib)(void *)GetProcAddress(h, "canInitializeLibrary");
	ct_kv_open     = (ct_kvOpen)(void *)GetProcAddress(h, "canOpenChannel");
	ct_kv_setbus   = (ct_kvSetBus)(void *)GetProcAddress(h, "canSetBusParams");
	ct_kv_setbusfd = (ct_kvSetBusFd)(void *)GetProcAddress(h, "canSetBusParamsFd");
	ct_kv_setoutctrl = (ct_kvSetOutCtrl)(void *)GetProcAddress(h, "canSetBusOutputControl");
	ct_kv_buson    = (ct_kvBusOn)(void *)GetProcAddress(h, "canBusOn");
	ct_kv_busoff   = (ct_kvBusOff)(void *)GetProcAddress(h, "canBusOff");
	ct_kv_write    = (ct_kvWrite)(void *)GetProcAddress(h, "canWrite");
	ct_kv_readwait = (ct_kvReadWait)(void *)GetProcAddress(h, "canReadWait");
	ct_kv_readstatus = (ct_kvReadStatus)(void *)GetProcAddress(h, "canReadStatus");
	ct_kv_close    = (ct_kvClose)(void *)GetProcAddress(h, "canClose");
	ct_kv_numchan  = (ct_kvNumChan)(void *)GetProcAddress(h, "canGetNumberOfChannels");
	ct_kv_chandata = (ct_kvChanData)(void *)GetProcAddress(h, "canGetChannelData");
	if (!ct_kv_initlib || !ct_kv_open || !ct_kv_setbus || !ct_kv_buson ||
		!ct_kv_write || !ct_kv_readwait || !ct_kv_close) return -2;
	return 0;
}

/* Total channels (physical + virtual), or -1 if unavailable. For discovery. */
static int ct_kvaser_count(void) {
	int n = 0;
	if (ct_kvaser_load() != 0 || !ct_kv_numchan) return -1;
	ct_kv_initlib();
	if (ct_kv_numchan(&n) < 0) return -1;
	return n;
}

/* Device description (ASCII) for channel `ch`. 0 ok (buf NUL-terminated), -1 not. */
static int ct_kvaser_descr(int ch, char *buf, int len) {
	if (len > 0) buf[0] = 0;
	if (!ct_kv_chandata) return -1;
	/* canCHANNELDATA_DEVDESCR_ASCII == 26 */
	if (ct_kv_chandata(ch, 26, buf, (size_t)len) < 0) { if (len > 0) buf[0] = 0; return -1; }
	return 0;
}


/* Is channel `ch` a SOFTWARE virtual channel? canCHANNELDATA_CHANNEL_CAP bit
 * canCHANNEL_CAP_VIRTUAL (0x00010000). Returns 1 virtual, 0 physical, -1 cannot say. */
static int ct_kvaser_is_virtual(int ch) {
	uint32_t cap = 0;
	if (!ct_kv_chandata) return -1;
	/* canCHANNELDATA_CHANNEL_CAP == 1 */
	if (ct_kv_chandata(ch, 1, &cap, sizeof cap) < 0) return -1;
	return (cap & 0x00010000L) ? 1 : 0;
}
/* Open channel `ch` (accepting virtual channels), set bitrate (a canBITRATE_* code,
 * negative), go bus-on. Returns the handle (>=0) or the negative canStatus error. */
static int ct_kvaser_open(int ch, int32_t bitrate_code) {
	int hnd, st;
	ct_kv_initlib();
	hnd = ct_kv_open(ch, CT_KV_OPEN_ACCEPT_VIRTUAL);
	if (hnd < 0) return hnd;
	st = ct_kv_setbus(hnd, bitrate_code, 0, 0, 0, 0, 0);
	if (st < 0) { ct_kv_close(hnd); return st; }
	st = ct_kv_buson(hnd);
	if (st < 0) { ct_kv_close(hnd); return st; }
	return hnd;
}

/* canStatus < 0 on error. */

/* Does this canlib have the CAN-FD API at all? Call after ct_kvaser_load(). */
static int ct_kvaser_has_fd(void) { return ct_kv_setbusfd ? 1 : 0; }

/* Open channel `ch` in CAN-FD mode: arbitration code, then the data-phase code, then bus-on.
 * Both are canlib's negative predefined constants (canBITRATE_* / canFD_BITRATE_*), which is
 * the pairing the bench run used. Returns the handle (>=0) or the negative canStatus. */
static int ct_kvaser_open_fd(int ch, int32_t arb_code, int32_t data_code) {
	int hnd, st;
	ct_kv_initlib();
	hnd = ct_kv_open(ch, CT_KV_OPEN_ACCEPT_VIRTUAL | CT_KV_OPEN_CAN_FD);
	if (hnd < 0) return hnd;
	st = ct_kv_setbus(hnd, arb_code, 0, 0, 0, 0, 0);
	if (st < 0) { ct_kv_close(hnd); return st; }
	st = ct_kv_setbusfd(hnd, data_code, 0, 0, 0);
	if (st < 0) { ct_kv_close(hnd); return st; }
	st = ct_kv_buson(hnd);
	if (st < 0) { ct_kv_close(hnd); return st; }
	return hnd;
}

/* Write a CAN-FD frame. `len` is a BYTE COUNT (canlib takes bytes here, not a DLC code) and the
 * caller has already checked it is one FD allows. BRS is per frame, not per bus. */
static int ct_kvaser_write_fd(int hnd, uint32_t id, uint8_t len, const uint8_t *data, int ext, int brs) {
	uint8_t buf[64];
	int i;
	uint32_t flag = (ext ? CT_KV_MSG_EXT : CT_KV_MSG_STD) | CT_KV_FDMSG_FDF;
	if (brs) flag |= CT_KV_FDMSG_BRS;
	if (len > 64) len = 64;
	for (i = 0; i < 64; i++) buf[i] = (i < len) ? data[i] : 0;
	return ct_kv_write(hnd, (int32_t)id, buf, len, flag);
}
static int ct_kvaser_write(int hnd, uint32_t id, uint8_t len, const uint8_t *data, int ext, int rtr) {
	uint8_t buf[8];
	int i;
	/* RTR rides the same flags word. It was dropped here, so a remote request went out as an
	 * ordinary data frame and reported success -- the same silent substitution the FD refusal
	 * above exists to prevent, one branch over. */
	uint32_t flag = (ext ? CT_KV_MSG_EXT : CT_KV_MSG_STD) | (rtr ? CT_KV_MSG_RTR : 0);
	if (len > 8) len = 8;
	for (i = 0; i < 8; i++) buf[i] = (i < len) ? data[i] : 0;
	return ct_kv_write(hnd, (int32_t)id, buf, len, flag);
}

/* Read one frame, blocking up to timeout_ms. Returns 0 (frame, out filled), 1 (timed out / no
 * message), or the negative canStatus.
 *
 * THE FLAGS WORD IS HANDED OUT WHOLE rather than picked apart here. What each bit means is a
 * decode, and a decode written in C is one no test can reach -- this one had already shipped
 * missing canMSG_RTR entirely (#177), which looked exactly like working code from the outside.
 * kvaser_decode_flags() in kvaser_names.v reads it, and the test beside that file pins the
 * constants to canlib's headers, the way health.v pins the fault ladder.
 *
 * ONE reader for both modes, with a 64-byte buffer. An FD-opened channel carries classic frames
 * too, and canlib writes only `dlc` bytes, so the wide buffer costs a classic read nothing and
 * is the difference between a 64-byte FD frame arriving and smashing the stack. `fd` and `brs`
 * are reported OUT rather than assumed from how the channel was opened: the bus tells us what
 * each frame was, which is the whole point of the flags. */
static int ct_kvaser_read(int hnd, uint32_t *id, uint8_t *len, uint8_t *data, uint32_t *flags, uint32_t timeout_ms) {
	int32_t cid = 0;
	/* ZEROED, because a REMOTE frame carries no data and canlib does not write any: it reports
	 * the requested DLC and leaves the buffer alone. Uninitialised, those bytes were whatever
	 * was on the stack, so a request for 8 bytes came back as 8 bytes of garbage -- and
	 * wiretap compares payloads, so the echo of our own request still failed to match and was
	 * filed as the ECU answering it. That is the #177 defect surviving its own fix for every
	 * DLC above zero (self-review). Every other backend hands a remote request up as zeroes of
	 * the requested length. */
	uint8_t buf[64] = {0};
	uint32_t dlc = 0, flag = 0, t = 0;
	int st = ct_kv_readwait(hnd, &cid, buf, &dlc, &flag, &t, timeout_ms);
	int i;
	if (st == CT_KV_ERR_NOMSG) return 1;
	if (st < 0) return st; /* negative canStatus error */
	*id = (uint32_t)cid;
	*len = (uint8_t)(dlc > 64 ? 64 : dlc);
	*flags = flag;
	for (i = 0; i < 64; i++) data[i] = buf[i];
	return 0;
}

/* ---- listen-only ---------------------------------------------------------------------------
 *
 * canDRIVER_SILENT makes the TRANSCEIVER listen without acknowledging, which is a different
 * promise from this process declining to transmit: an ACK is generated by the controller itself,
 * so software refusing to send does not stop it. On a bus with one other node our acknowledgement
 * is the difference between its frames succeeding and it going error-passive.
 *
 * canlib demands the channel be bus-OFF while this is set, so a change mid-run bounces the bus.
 * That is the honest cost and the caller decides when to pay it.
 */
#define CT_KV_DRIVER_SILENT 1
#define CT_KV_DRIVER_NORMAL 4

/* canSetBusOutputControl is only accepted while the channel is bus-OFF, so the bus is bounced
   around it -- AND BROUGHT BACK UP WHICHEVER WAY THE CALL GOES. Returning early on a refused
   mode change left the channel off the bus and handed the caller a handle that looked like a
   working one: it would transmit nothing, receive nothing, and be taken off the bus again on
   every subsequent reconcile. A driver that will not change the mode is a reason to report the
   mode unchanged, never a reason to leave the wire down (self-review of #219). */
static int ct_kvaser_set_silent(int hnd, int silent) {
	int st, on;
	if (!ct_kv_setoutctrl) return -100; /* canERR_NOT_IMPLEMENTED-ish: caller reports it */
	if (ct_kv_busoff) ct_kv_busoff(hnd);
	st = ct_kv_setoutctrl(hnd, silent ? CT_KV_DRIVER_SILENT : CT_KV_DRIVER_NORMAL);
	on = ct_kv_buson ? ct_kv_buson(hnd) : 0;
	if (st < 0) return st; /* the mode did not change; the bus is back up regardless */
	return on < 0 ? on : 0;
}

static void ct_kvaser_close(int hnd) {
	if (hnd >= 0) { ct_kv_busoff(hnd); ct_kv_close(hnd); }
}

/* Status flags of an on-bus handle. Returns -1 when the symbol is absent or the call fails
 * (the caller reads that as "cannot say"); 0 on success with *flags filled. */
static int ct_kvaser_status(int hnd, uint32_t *flags) {
	if (!ct_kv_readstatus) return -1;
	return ct_kv_readstatus(hnd, flags) == 0 ? 0 : -1;
}

#endif /* CT_KVASER_SHIM_H */
