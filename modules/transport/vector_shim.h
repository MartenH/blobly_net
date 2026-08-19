/* vector_shim.h — flat C wrappers over Vector's XL Driver Library (vxlapi64.dll),
 * resolved at RUNTIME via LoadLibrary/GetProcAddress (no SDK, no import .lib; mingw or
 * MSVC). Same pattern as pcan_shim.h / kvaser_shim.h. Windows-only (included only by
 * vector_windows.v). vxlapi64.dll ships with the Vector Driver Setup.
 *
 * ADDRESSED BY APPLICATION CHANNEL, not by hardware index, so this file needs no part of
 * XLdriverConfig — a packed struct of some forty fields whose exact size decides where its
 * channel array begins. Reproducing that from documentation would fail by reading out of
 * bounds rather than by returning an error, and there is no way to check it from the machine
 * this is written on. xlGetApplConfig/xlGetChannelMask take scalars only.
 *
 * XLstatus is `short` in vxlapi.h. Declared that way here DELIBERATELY, and it is the safe
 * choice even if the header were `int`: the callee returns in EAX, and reading AX of an int
 * return is still correct for every status value the library defines (0..255), while reading
 * EAX of a short return picks up whatever was in the high half.
 *
 * Win64 LLP64: `long` is 32-bit, so XLportHandle is int32_t. XLaccess is a 64-bit mask.
 */
#ifndef CT_VECTOR_SHIM_H
#define CT_VECTOR_SHIM_H

#include <windows.h>
#include <stdint.h>

#define CT_XL_BUS_TYPE_CAN        0x00000001
#define CT_XL_INTERFACE_VERSION   3          /* V3 = classic CAN */
#define CT_XL_ACTIVATE_RESET_CLOCK 8
#define CT_XL_OUTPUT_MODE_SILENT  0          /* ACK-free: the bus cannot be disturbed */
#define CT_XL_OUTPUT_MODE_NORMAL  1
#define CT_XL_RECEIVE_MSG         1
#define CT_XL_TRANSMIT_MSG        10
#define CT_XL_ERR_QUEUE_IS_EMPTY  10
#define CT_XL_CAN_EXT_MSG_ID      0x80000000
#define CT_XL_CAN_MSG_FLAG_ERROR_FRAME  0x01
#define CT_XL_CAN_MSG_FLAG_REMOTE_FRAME 0x10
#define CT_XL_CAN_MSG_FLAG_TX_COMPLETED 0x40
#define CT_XL_CAN_MSG_FLAG_TX_REQUEST   0x80
#define CT_XL_INVALID_PORTHANDLE  (-1)

typedef int16_t  ct_xlstatus;
typedef int32_t  ct_xlport;
typedef uint64_t ct_xlaccess;

/* XLevent, classic CAN. 16-byte header + a 32-byte union = 48 bytes, and the layout is the
 * same under pack(1) and default packing because every member already sits on its natural
 * offset. _Static_assert below refuses to build if that is ever untrue rather than sending
 * a misaligned frame at a live ECU. */
#pragma pack(push, 1)
typedef struct {
	uint32_t id;
	uint16_t flags;
	uint16_t dlc;
	uint64_t res1;
	uint8_t  data[8];
	uint64_t res2;
} ct_xl_can_msg;

typedef struct {
	uint8_t  tag;
	uint8_t  chanIndex;
	uint16_t transId;
	uint16_t portHandle;
	uint8_t  flags;
	uint8_t  reserved;
	uint64_t timeStamp;
	union {
		ct_xl_can_msg msg;
		uint8_t       raw[32];
	} tagData;
} ct_xlevent;
#pragma pack(pop)

_Static_assert(sizeof(ct_xl_can_msg) == 32, "XL CAN message must be 32 bytes");
_Static_assert(sizeof(ct_xlevent) == 48, "XLevent must be 48 bytes");

typedef ct_xlstatus (__stdcall *ct_xlOpenDriver)(void);
typedef ct_xlstatus (__stdcall *ct_xlCloseDriver)(void);
typedef ct_xlstatus (__stdcall *ct_xlGetApplConfig)(char *, unsigned int, unsigned int *, unsigned int *, unsigned int *, unsigned int);
typedef ct_xlstatus (__stdcall *ct_xlSetApplConfig)(char *, unsigned int, unsigned int, unsigned int, unsigned int, unsigned int);
typedef ct_xlaccess (__stdcall *ct_xlGetChannelMask)(int, int, int);
typedef ct_xlstatus (__stdcall *ct_xlOpenPort)(ct_xlport *, char *, ct_xlaccess, ct_xlaccess *, unsigned int, unsigned int, unsigned int);
typedef ct_xlstatus (__stdcall *ct_xlClosePort)(ct_xlport);
typedef ct_xlstatus (__stdcall *ct_xlSetBitrate)(ct_xlport, ct_xlaccess, unsigned int);
typedef ct_xlstatus (__stdcall *ct_xlSetOutput)(ct_xlport, ct_xlaccess, unsigned int);
typedef ct_xlstatus (__stdcall *ct_xlSetChanMode)(ct_xlport, ct_xlaccess, int, int);
typedef ct_xlstatus (__stdcall *ct_xlActivate)(ct_xlport, ct_xlaccess, unsigned int, unsigned int);
typedef ct_xlstatus (__stdcall *ct_xlDeactivate)(ct_xlport, ct_xlaccess);
typedef ct_xlstatus (__stdcall *ct_xlTransmit)(ct_xlport, ct_xlaccess, unsigned int *, void *);
typedef ct_xlstatus (__stdcall *ct_xlReceive)(ct_xlport, unsigned int *, void *);
typedef ct_xlstatus (__stdcall *ct_xlSetNotify)(ct_xlport, HANDLE *, int);
typedef char *      (__stdcall *ct_xlGetErrString)(ct_xlstatus);

static ct_xlOpenDriver     ct_xl_opendrv;
static ct_xlCloseDriver    ct_xl_closedrv;
static ct_xlGetApplConfig  ct_xl_getappl;
static ct_xlSetApplConfig  ct_xl_setappl;
static ct_xlGetChannelMask ct_xl_chanmask;
static ct_xlOpenPort       ct_xl_openport;
static ct_xlClosePort      ct_xl_closeport;
static ct_xlSetBitrate     ct_xl_setbitrate;
static ct_xlSetOutput      ct_xl_setoutput;
static ct_xlSetChanMode    ct_xl_setchanmode;
static ct_xlActivate       ct_xl_activate;
static ct_xlDeactivate     ct_xl_deactivate;
static ct_xlTransmit       ct_xl_transmit;
static ct_xlReceive        ct_xl_receive;
static ct_xlSetNotify      ct_xl_setnotify;
static ct_xlGetErrString   ct_xl_errstr;

static int ct_vector_loaded = 0;

/* WHAT WE CONFIGURED, per channel, for the life of this process.
 *
 * The application does not open one port per bus: a monitor opens its own, and each tapped
 * transmit path opens another, all on the same channel. Only the FIRST of those keeps
 * initialisation access — XL grants it once — so the later ones legitimately arrive with no
 * right to set the bitrate. Refusing them outright leaves a channel running with no monitor, or
 * no way to transmit, depending on which open lost the race.
 *
 * So the question a secondary open has to answer is not "may I configure this channel" but "is
 * it already configured the way I would have configured it". That is answerable only by
 * remembering what we did, because XL will not tell us what rate a channel is running at.
 * A channel we never configured, denied to us now, belongs to another application. */
/* XL_CONFIG_MAX_CHANNELS, which is also the range vector_app_channel accepts. Sized at 16 with
 * a remark about what a bench plausibly has, this silently stopped recording past the sixteenth
 * channel — and because the GUI opens several ports per channel, the FIRST port then succeeded
 * while every later one was denied init access and refused. A limit the parser does not enforce
 * is not a limit; the table matches the range instead of guessing at it. */
#define CT_VEC_MAX_CFG 64
static uint64_t ct_vec_cfg_mask[CT_VEC_MAX_CFG];
static unsigned int ct_vec_cfg_rate[CT_VEC_MAX_CFG];
static int ct_vec_cfg_silent[CT_VEC_MAX_CFG];
static int ct_vec_cfg_ports[CT_VEC_MAX_CFG];
static ct_xlport ct_vec_cfg_owner[CT_VEC_MAX_CFG];
static int ct_vec_cfg_n = 0;

/* One lock over the symbol table and the configuration record. Those opens happen from several
 * threads at once — the monitor spawns while the transmit taps are being created — and both
 * structures are written on first use. */
static CRITICAL_SECTION ct_vec_lock;
static INIT_ONCE ct_vec_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK ct_vec_init_lock(PINIT_ONCE o, PVOID p, PVOID *c) {
	(void)o; (void)p; (void)c;
	InitializeCriticalSection(&ct_vec_lock);
	return TRUE;
}
static void ct_vec_enter(void) {
	InitOnceExecuteOnce(&ct_vec_once, ct_vec_init_lock, NULL, NULL);
	EnterCriticalSection(&ct_vec_lock);
}
static void ct_vec_leave(void) { LeaveCriticalSection(&ct_vec_lock); }

static int ct_vec_cfg_find(uint64_t mask) {
	int i;
	for (i = 0; i < ct_vec_cfg_n; i++) if (ct_vec_cfg_mask[i] == mask) return i;
	return -1;
}

/* 0 recorded, -1 full. FAILS rather than forgetting: a channel we configured but did not record
 * is one whose secondary ports will all be refused, which reads as hardware trouble. With the
 * table sized to the whole accepted range this cannot happen, and saying so costs one branch. */
static int ct_vec_cfg_note(uint64_t mask, unsigned int rate, int silent, ct_xlport owner) {
	int i = ct_vec_cfg_find(mask);
	if (i < 0) {
		if (ct_vec_cfg_n >= CT_VEC_MAX_CFG) return -1;
		i = ct_vec_cfg_n++;
		ct_vec_cfg_mask[i] = mask;
		ct_vec_cfg_ports[i] = 0;
	}
	ct_vec_cfg_rate[i] = rate;
	ct_vec_cfg_silent[i] = silent;
	ct_vec_cfg_owner[i] = owner;
	return 0;
}

/* Count a port against the channel it opened, and FORGET the channel when the last one goes.
 * Kept for the life of the process, the record outlived the ports: stop, let another XL
 * application take initialisation access and change the rate, start again, and the reopen is
 * denied init access but matches a memory of how WE last configured it — reporting success on a
 * bus running at somebody else's rate. What we know is only true while we hold a port. */
static void ct_vec_cfg_ref(uint64_t mask) {
	int i = ct_vec_cfg_find(mask);
	if (i >= 0) ct_vec_cfg_ports[i]++;
}

static void ct_vec_cfg_forget(int i) {
	ct_vec_cfg_n--;
	if (i != ct_vec_cfg_n) { /* keep the array dense */
		ct_vec_cfg_mask[i]   = ct_vec_cfg_mask[ct_vec_cfg_n];
		ct_vec_cfg_rate[i]   = ct_vec_cfg_rate[ct_vec_cfg_n];
		ct_vec_cfg_silent[i] = ct_vec_cfg_silent[ct_vec_cfg_n];
		ct_vec_cfg_ports[i]  = ct_vec_cfg_ports[ct_vec_cfg_n];
		ct_vec_cfg_owner[i]  = ct_vec_cfg_owner[ct_vec_cfg_n];
	}
}

/* INITIALISATION ACCESS BELONGS TO A PORT, not to the channel. When the port that holds it
 * closes, XL releases that access even though our other ports on the same wire stay open — so
 * another application can take it and change the rate or the output mode, and everything we
 * remember about the channel stops being true at that moment rather than when our last port
 * goes. The record is dropped with its owner; ports still open keep running, but nothing new is
 * admitted on the strength of what we used to know. */
static void ct_vec_cfg_unref(uint64_t mask, ct_xlport port) {
	int i = ct_vec_cfg_find(mask);
	if (i < 0) return;
	if (ct_vec_cfg_owner[i] == port) { ct_vec_cfg_forget(i); return; }
	if (--ct_vec_cfg_ports[i] > 0) return;
	ct_vec_cfg_n--;
	if (i != ct_vec_cfg_n) { /* keep the array dense */
		ct_vec_cfg_mask[i]   = ct_vec_cfg_mask[ct_vec_cfg_n];
		ct_vec_cfg_rate[i]   = ct_vec_cfg_rate[ct_vec_cfg_n];
		ct_vec_cfg_silent[i] = ct_vec_cfg_silent[ct_vec_cfg_n];
		ct_vec_cfg_ports[i]  = ct_vec_cfg_ports[ct_vec_cfg_n];
	}
}

/* 0 ok, -1 DLL missing, -2 a symbol missing. */
static int ct_vector_load(void) {
	HMODULE h;
	if (ct_vector_loaded) return 0;
	h = LoadLibraryA("vxlapi64.dll");
	if (!h) h = LoadLibraryA("vxlapi.dll"); /* 32-bit host, same ABI shape */
	if (!h) return -1;
	ct_xl_opendrv    = (ct_xlOpenDriver)(void *)GetProcAddress(h, "xlOpenDriver");
	ct_xl_closedrv   = (ct_xlCloseDriver)(void *)GetProcAddress(h, "xlCloseDriver");
	ct_xl_getappl    = (ct_xlGetApplConfig)(void *)GetProcAddress(h, "xlGetApplConfig");
	ct_xl_setappl    = (ct_xlSetApplConfig)(void *)GetProcAddress(h, "xlSetApplConfig");
	ct_xl_chanmask   = (ct_xlGetChannelMask)(void *)GetProcAddress(h, "xlGetChannelMask");
	ct_xl_openport   = (ct_xlOpenPort)(void *)GetProcAddress(h, "xlOpenPort");
	ct_xl_closeport  = (ct_xlClosePort)(void *)GetProcAddress(h, "xlClosePort");
	ct_xl_setbitrate = (ct_xlSetBitrate)(void *)GetProcAddress(h, "xlCanSetChannelBitrate");
	ct_xl_setoutput  = (ct_xlSetOutput)(void *)GetProcAddress(h, "xlCanSetChannelOutput");
	ct_xl_setchanmode = (ct_xlSetChanMode)(void *)GetProcAddress(h, "xlCanSetChannelMode");
	ct_xl_activate   = (ct_xlActivate)(void *)GetProcAddress(h, "xlActivateChannel");
	ct_xl_deactivate = (ct_xlDeactivate)(void *)GetProcAddress(h, "xlDeactivateChannel");
	ct_xl_transmit   = (ct_xlTransmit)(void *)GetProcAddress(h, "xlCanTransmit");
	ct_xl_receive    = (ct_xlReceive)(void *)GetProcAddress(h, "xlReceive");
	ct_xl_setnotify  = (ct_xlSetNotify)(void *)GetProcAddress(h, "xlSetNotification");
	ct_xl_errstr     = (ct_xlGetErrString)(void *)GetProcAddress(h, "xlGetErrorString");
	if (!ct_xl_opendrv || !ct_xl_getappl || !ct_xl_chanmask || !ct_xl_openport ||
	    !ct_xl_closeport || !ct_xl_setbitrate || !ct_xl_activate || !ct_xl_deactivate ||
	    !ct_xl_transmit || !ct_xl_receive || !ct_xl_setnotify) return -2;
	ct_vector_loaded = 1;
	return 0;
}

/* Human-readable XL status, or "" when the DLL predates xlGetErrorString. */
static const char *ct_vector_err(int st) {
	if (!ct_xl_errstr) return "";
	return ct_xl_errstr((ct_xlstatus)st);
}

/* Resolve an application channel (0-based here) to a channel mask.
 * Returns 0 when the application channel has no hardware assigned, having REGISTERED the
 * application first so it appears in Vector Hardware Configuration for the operator to
 * assign — an unconfigured app is otherwise invisible there, and the error alone would send
 * them looking for a dialog entry that does not exist. */
static uint64_t ct_vector_mask_why(unsigned int app_channel, int *why) {
	unsigned int hw_type = 0, hw_index = 0, hw_channel = 0;
	int rc;
	ct_xlstatus st;
	if (why) *why = 0;
	rc = ct_vector_load();
	if (rc != 0) { if (why) *why = rc; return 0; }          /* -1 no DLL, -2 no symbol */
	st = ct_xl_opendrv();
	if (st != 0) { if (why) *why = -(int)st; return 0; }    /* driver would not open */
	if (ct_xl_getappl("blobly_net", app_channel, &hw_type, &hw_index, &hw_channel,
	                  CT_XL_BUS_TYPE_CAN) != 0 || hw_type == 0) {
		if (ct_xl_setappl) {
			ct_xl_setappl("blobly_net", app_channel, 0, 0, 0, CT_XL_BUS_TYPE_CAN);
		}
		if (why) *why = -1000; /* driver fine, this channel simply has no hardware yet */
		return 0;
	}
	return (uint64_t)ct_xl_chanmask((int)hw_type, (int)hw_index, (int)hw_channel);
}

static uint64_t ct_vector_mask(unsigned int app_channel) {
	return ct_vector_mask_why(app_channel, NULL);
}

/* Open, configure and activate one application channel.
 * `silent` puts the transceiver in ACK-free listen mode BEFORE the channel goes on the bus,
 * which is the only order that is safe on a live one: a channel activated normally at the
 * wrong bitrate acknowledges nothing correctly and floods error frames.
 * Returns 0, or a negative XL status. Outputs port + mask on success. */
static int ct_vector_open(unsigned int app_channel, unsigned int bitrate, int silent,
                          ct_xlport *out_port, uint64_t *out_mask, HANDLE *out_event) {
	ct_xlaccess mask, permission;
	ct_xlport port = CT_XL_INVALID_PORTHANDLE;
	ct_xlstatus st;
	int why = 0;
	ct_vec_enter();
	mask = (ct_xlaccess)ct_vector_mask_why(app_channel, &why);
	if (!mask) { ct_vec_leave(); return why ? why : -1000; } /* the caller distinguishes these; see vector_windows.v */
	/* permissionMask is IN/OUT: on the way IN it asks for INIT ACCESS on these channels, and on
	 * the way OUT it says which were granted. Passing 0 asks for init access on nothing, so the
	 * bitrate below is never applied — the channel keeps whatever rate the last application left
	 * on it — and xlCanSetChannelOutput is refused for want of access, which fails every silent
	 * open. Asking for the channel we are opening is what the XL examples do and what makes the
	 * two calls after this one mean anything. */
	permission = mask;
	st = ct_xl_openport(&port, "blobly_net", mask, &permission, 256, CT_XL_INTERFACE_VERSION,
	                    CT_XL_BUS_TYPE_CAN);
	if (st != 0 || port == CT_XL_INVALID_PORTHANDLE) { ct_vec_leave(); return st ? -(int)st : -1001; }
	/* Init access decides whether this port may set the bitrate at all. Without it another
	 * application already owns the channel's parameters, and setting them would either fail
	 * or reconfigure a bus somebody else is using. */
	if (permission & mask) {
		st = ct_xl_setbitrate(port, mask, bitrate);
		if (st != 0) { ct_xl_closeport(port); ct_vec_leave(); return -(int)st; }
		if (ct_xl_setoutput) {
			st = ct_xl_setoutput(port, mask, silent ? CT_XL_OUTPUT_MODE_SILENT : CT_XL_OUTPUT_MODE_NORMAL);
			if (st != 0 && silent) { ct_xl_closeport(port); ct_vec_leave(); return -(int)st; }
		} else if (silent) {
			ct_xl_closeport(port); ct_vec_leave(); return -1002;
		}
		if (ct_vec_cfg_note(mask, bitrate, silent, port) != 0) {
			ct_xl_closeport(port); ct_vec_leave(); return -1006;
		}
		ct_vec_cfg_ref(mask);
	} else {
		/* No init access. Either we already configured this channel — a second port for a bus
		 * this process is running, which is normal and must work — or somebody else owns it. */
		int i = ct_vec_cfg_find(mask);
		if (i < 0) { ct_xl_closeport(port); ct_vec_leave(); return -1003; }
		/* Configured by us, but not the way this caller asked. Reported rather than papered
		 * over: a port that believes it is silent while the channel acknowledges is the exact
		 * promise this backend was added to keep. */
		/* BOTH DIRECTIONS. Refusing only a silent request after a normal open leaves the other
		 * half wrong in the more dangerous way: a normal port on a channel we configured silent
		 * would report itself able to transmit, and send() and the trace would treat frames as
		 * having gone out while the transceiver acknowledged nothing. */
		if (silent != ct_vec_cfg_silent[i]) { ct_xl_closeport(port); ct_vec_leave(); return -1004; }
		if (ct_vec_cfg_rate[i] != bitrate) { ct_xl_closeport(port); ct_vec_leave(); return -1005; }
		ct_vec_cfg_ports[i]++;
	}
	/* No TX confirmations and no TX requests in the receive queue. The XL driver can deliver an
	 * event for every frame WE send, and echoes_own_sends() reports false for a vendor backend —
	 * so anything that arrived here would be filed as traffic the ECU produced. Belt and braces:
	 * the flags are filtered on read too, because an older DLL may not export this call. */
	if (ct_xl_setchanmode) ct_xl_setchanmode(port, mask, 0, 0);
	if (ct_xl_setnotify(port, out_event, 1) != 0) *out_event = NULL;
	st = ct_xl_activate(port, mask, CT_XL_BUS_TYPE_CAN, CT_XL_ACTIVATE_RESET_CLOCK);
	if (st != 0) {
		/* The reference was taken above; drop it here rather than in ct_vector_close, which the
		 * caller never reaches for a port that failed to activate. */
		ct_vec_cfg_unref(mask, port);
		ct_xl_closeport(port);
		ct_vec_leave();
		return -(int)st;
	}
	*out_port = port;
	*out_mask = (uint64_t)mask;
	ct_vec_leave();
	return 0;
}

/* 0 ok, negative XL status on failure. */
static int ct_vector_write(ct_xlport port, uint64_t mask, uint32_t id, uint8_t len,
                           const uint8_t *data, int ext, int rtr) {
	ct_xlevent ev;
	unsigned int count = 1;
	int i;
	ct_xlstatus st;
	memset(&ev, 0, sizeof(ev));
	ev.tag = CT_XL_TRANSMIT_MSG;
	ev.tagData.msg.id = ext ? (id | CT_XL_CAN_EXT_MSG_ID) : id;
	ev.tagData.msg.dlc = len > 8 ? 8 : len;
	ev.tagData.msg.flags = rtr ? CT_XL_CAN_MSG_FLAG_REMOTE_FRAME : 0;
	for (i = 0; i < 8 && i < len; i++) ev.tagData.msg.data[i] = data[i];
	st = ct_xl_transmit(port, (ct_xlaccess)mask, &count, &ev);
	return st == 0 ? 0 : -(int)st;
}

/* Read one CAN frame, waiting up to timeout_ms. 0 = frame, 1 = nothing within the timeout,
 * negative = XL status. Non-message events and error frames are skipped, not reported as
 * frames: an error frame carries no payload and filing one as bus traffic would put a
 * message on the trace that nobody sent. */
static int ct_vector_read(ct_xlport port, HANDLE ev_handle, uint32_t *id, uint8_t *len,
                          uint8_t *data, int *ext, int *rtr, int timeout_ms) {
	ct_xlevent ev;
	unsigned int count;
	DWORD waited;
	int i;
	ct_xlstatus st;
	/* Against a DEADLINE, not a budget that is spent by the first wake. The notification fires
	 * for events that are not CAN frames too, and collapsing the remaining time to zero after
	 * one of those turned `recv(200)` into a busy poll that reported a timeout it had not
	 * waited for. */
	ULONGLONG started = GetTickCount64();
	DWORD budget;
	for (;;) {
		count = 1;
		st = ct_xl_receive(port, &count, &ev);
		if (st == 0 && count > 0) {
			if (ev.tag != CT_XL_RECEIVE_MSG) continue;
			/* An error frame carries no payload, and a TX confirmation is OUR OWN frame coming
			 * back: filing either as bus traffic puts a message on the trace nobody sent. */
			if (ev.tagData.msg.flags & CT_XL_CAN_MSG_FLAG_ERROR_FRAME) continue;
			if (ev.tagData.msg.flags & (CT_XL_CAN_MSG_FLAG_TX_COMPLETED | CT_XL_CAN_MSG_FLAG_TX_REQUEST)) continue;
			*rtr = (ev.tagData.msg.flags & CT_XL_CAN_MSG_FLAG_REMOTE_FRAME) ? 1 : 0;
			*ext = (ev.tagData.msg.id & CT_XL_CAN_EXT_MSG_ID) ? 1 : 0;
			*id  = ev.tagData.msg.id & 0x1FFFFFFF;
			*len = (uint8_t)(ev.tagData.msg.dlc > 8 ? 8 : ev.tagData.msg.dlc);
			for (i = 0; i < 8; i++) data[i] = ev.tagData.msg.data[i];
			return 0;
		}
		if (st != CT_XL_ERR_QUEUE_IS_EMPTY && st != 0) return -(int)st;
		if (!ev_handle) return 1; /* no notification handle: report empty rather than spin */
		if (timeout_ms < 0) {
			budget = INFINITE;
		} else {
			ULONGLONG gone = GetTickCount64() - started;
			if (gone >= (ULONGLONG)timeout_ms) return 1;
			budget = (DWORD)((ULONGLONG)timeout_ms - gone);
		}
		waited = WaitForSingleObject(ev_handle, budget);
		if (waited != WAIT_OBJECT_0) return 1; /* timed out */
	}
}

static void ct_vector_close(ct_xlport port, uint64_t mask) {
	if (port == CT_XL_INVALID_PORTHANDLE) return;
	/* UNDER THE LOCK, AND BEFORE xlClosePort. A port handle is a small reusable number: closing
	 * first releases it, an open racing this call can be handed the same value and become the
	 * recorded owner, and the cleanup that followed would then delete the NEW channel's record
	 * on the strength of the old port's number. Every same-process tap after that is refused for
	 * want of a record. Releasing the record while the handle is still ours makes the identity
	 * unambiguous without having to invent generations for it. */
	ct_vec_enter();
	ct_vec_cfg_unref(mask, port);
	ct_xl_deactivate(port, (ct_xlaccess)mask);
	ct_xl_closeport(port);
	ct_vec_leave();
}

/* How far the driver gets, so a caller can tell apart failures that look identical from
 * outside: 0 = vxlapi loaded and the driver opened, -1 = DLL not present, -2 = DLL present but
 * missing a symbol we need, or a negative XL status from xlOpenDriver. "Nothing to list" and
 * "nothing installed" are different problems with different fixes, and reporting one message
 * for both sends people to the wrong dialog. */
static int ct_vector_diag(void) {
	int rc = ct_vector_load();
	ct_xlstatus st;
	if (rc != 0) return rc;
	st = ct_xl_opendrv();
	if (st != 0) return -(int)st;
	return 0;
}

/* Is an application channel assigned to hardware? For discovery. */
static int ct_vector_present(unsigned int app_channel) {
	return ct_vector_mask(app_channel) != 0;
}

#endif /* CT_VECTOR_SHIM_H */
