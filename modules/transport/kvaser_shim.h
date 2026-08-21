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
#define CT_KV_ERR_NOMSG        (-2)

typedef void    (__stdcall *ct_kvInitLib)(void);
typedef int     (__stdcall *ct_kvOpen)(int, int);
typedef int     (__stdcall *ct_kvSetBus)(int, int32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
typedef int     (__stdcall *ct_kvBusOn)(int);
typedef int     (__stdcall *ct_kvBusOff)(int);
typedef int     (__stdcall *ct_kvWrite)(int, int32_t, void *, uint32_t, uint32_t);
typedef int     (__stdcall *ct_kvReadWait)(int, int32_t *, void *, uint32_t *, uint32_t *, uint32_t *, uint32_t);
typedef int     (__stdcall *ct_kvClose)(int);

static ct_kvInitLib  ct_kv_initlib;
static ct_kvOpen     ct_kv_open;
static ct_kvSetBus   ct_kv_setbus;
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

/* bus health (optional): canReadStatus fills canSTAT_* flags — BUS_OFF 0x01, ERROR_PASSIVE
 * 0x02, ERROR_WARNING 0x40, ERROR_ACTIVE 0x10 (canstat.h). */
typedef int (__stdcall *ct_kvReadStatus)(int, uint32_t *);
static ct_kvReadStatus ct_kv_readstatus;

/* 0 ok, -1 DLL missing, -2 a symbol missing. */
static int ct_kvaser_load(void) {
	HMODULE h = LoadLibraryA("canlib32.dll");
	if (!h) return -1;
	ct_kv_initlib  = (ct_kvInitLib)(void *)GetProcAddress(h, "canInitializeLibrary");
	ct_kv_open     = (ct_kvOpen)(void *)GetProcAddress(h, "canOpenChannel");
	ct_kv_setbus   = (ct_kvSetBus)(void *)GetProcAddress(h, "canSetBusParams");
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
static int ct_kvaser_write(int hnd, uint32_t id, uint8_t len, const uint8_t *data, int ext) {
	uint8_t buf[8];
	int i;
	uint32_t flag = ext ? CT_KV_MSG_EXT : CT_KV_MSG_STD;
	if (len > 8) len = 8;
	for (i = 0; i < 8; i++) buf[i] = (i < len) ? data[i] : 0;
	return ct_kv_write(hnd, (int32_t)id, buf, len, flag);
}

/* Read one frame, blocking up to timeout_ms. Returns 0 (frame, out filled),
 * 1 (timed out / no message), or -(status) on error. Error frames are reported as 1
 * (skip). */
static int ct_kvaser_read(int hnd, uint32_t *id, uint8_t *len, uint8_t *data, int *ext, uint32_t timeout_ms) {
	int32_t cid = 0;
	uint8_t buf[8];
	uint32_t dlc = 0, flag = 0, t = 0;
	int st = ct_kv_readwait(hnd, &cid, buf, &dlc, &flag, &t, timeout_ms);
	int i;
	if (st == CT_KV_ERR_NOMSG) return 1;
	if (st < 0) return st; /* negative canStatus error */
	if (flag & CT_KV_MSG_ERROR_FRAME) return 1;
	*id = (uint32_t)cid;
	*len = (uint8_t)(dlc > 8 ? 8 : dlc);
	*ext = (flag & CT_KV_MSG_EXT) ? 1 : 0;
	for (i = 0; i < 8; i++) data[i] = buf[i];
	return 0;
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
