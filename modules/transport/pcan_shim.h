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
#define CT_PCAN_ERROR_OK        0x00000u
#define CT_PCAN_ERROR_QRCVEMPTY 0x00020u

typedef struct {
	uint32_t ID;       /* 11/29-bit id */
	uint8_t  MSGTYPE;  /* CT_PCAN_MSG_* bit flags */
	uint8_t  LEN;      /* 0..8 */
	uint8_t  DATA[8];
} CT_TPCANMsg;

typedef uint32_t (__stdcall *ct_pInit)(uint16_t, uint16_t, uint8_t, uint32_t, uint16_t);
typedef uint32_t (__stdcall *ct_pUninit)(uint16_t);
typedef uint32_t (__stdcall *ct_pWrite)(uint16_t, CT_TPCANMsg *);
typedef uint32_t (__stdcall *ct_pRead)(uint16_t, CT_TPCANMsg *, void *);

static ct_pInit   ct_fn_init;
static ct_pUninit ct_fn_uninit;
static ct_pWrite  ct_fn_write;
static ct_pRead   ct_fn_read;

/* Load the DLL + resolve the four entry points. 0 ok, -1 DLL missing, -2 symbol missing. */
static int ct_pcan_load(void) {
	HMODULE h = LoadLibraryA("PCANBasic.dll");
	if (!h) return -1;
	ct_fn_init   = (ct_pInit)(void *)GetProcAddress(h, "CAN_Initialize");
	ct_fn_uninit = (ct_pUninit)(void *)GetProcAddress(h, "CAN_Uninitialize");
	ct_fn_write  = (ct_pWrite)(void *)GetProcAddress(h, "CAN_Write");
	ct_fn_read   = (ct_pRead)(void *)GetProcAddress(h, "CAN_Read");
	if (!ct_fn_init || !ct_fn_uninit || !ct_fn_write || !ct_fn_read) return -2;
	return 0;
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

/* Read one message. Returns 0 (got a frame, out params filled), 1 (queue empty —
 * caller should poll/timeout), or -(status) on a real error. */
static int ct_pcan_read(uint16_t ch, uint32_t *id, uint8_t *msgtype, uint8_t *len, uint8_t *data) {
	CT_TPCANMsg m;
	uint32_t st = ct_fn_read(ch, &m, NULL);
	int i;
	if (st == CT_PCAN_ERROR_QRCVEMPTY) return 1;
	if (st != CT_PCAN_ERROR_OK) return -(int)st;
	*id = m.ID;
	*msgtype = m.MSGTYPE;
	*len = m.LEN;
	for (i = 0; i < 8; i++) data[i] = m.DATA[i];
	return 0;
}

#endif /* CT_PCAN_SHIM_H */
