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
 * CHECKED AGAINST vxlapi.h 25.20.14, which the operator's XL Driver Library install ships:
 * XLstatus is `short`, XLaccess is `XLuint64`, XLportHandle is `XLlong` = `long` = 32-bit here,
 * XLevent is 48 bytes and s_xl_can_msg 32, and every constant and signature below matches. The
 * header is NOT included: we cannot depend on a library we are forbidden to ship being present
 * at build time, and the whole point of this file is that it needs no SDK. Verified against it,
 * not built against it.
 *
 * Win64 LLP64: `long` is 32-bit, so XLportHandle is int32_t. XLaccess is a 64-bit mask.
 */
#ifndef CT_VECTOR_SHIM_H
#define CT_VECTOR_SHIM_H

#include <windows.h>
#include <stdint.h>
#include <stdio.h>   /* snprintf, for the install-directory search */
#include <string.h>
#include <stddef.h>  /* offsetof, for the layout assertions */

#define CT_XL_BUS_TYPE_CAN        0x00000001
#define CT_XL_INTERFACE_VERSION   3          /* V3 = classic CAN */
/* NO FLAGS on activation. vxlapi.h says of XL_ACTIVATE_RESET_CLOCK (8): "using this flag with
 * time synchronisation protocols supported by Vector Timesync Service is not recommended" — and
 * that service is installed alongside the driver, so on an ordinary Vector bench it is running.
 * Resetting the clock per activation would also give each of our ports its own zero, which is
 * the opposite of what a multi-channel tester wants: the shared timebase is what makes two VN
 * channels comparable. */
#define CT_XL_ACTIVATE_NONE 0
#define CT_XL_OUTPUT_MODE_SILENT  0          /* ACK-free: the bus cannot be disturbed */
#define CT_XL_OUTPUT_MODE_NORMAL  1
#define CT_XL_RECEIVE_MSG         1
#define CT_XL_CHIP_STATE          4
#define CT_XL_CHIPSTAT_BUSOFF        0x01
#define CT_XL_CHIPSTAT_ERROR_PASSIVE 0x02
#define CT_XL_CHIPSTAT_ERROR_WARNING 0x04
#define CT_XL_CHIPSTAT_ERROR_ACTIVE  0x08
#define CT_XL_TRANSMIT_MSG        10
#define CT_XL_ERR_QUEUE_IS_EMPTY  10
#define CT_XL_ERR_QUEUE_IS_FULL   11
#define CT_XL_ERR_TX_NOT_POSSIBLE 12
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
/* `XLulong` and `int mode` as vxlapi.h declares them. Both are ABI-identical to the unsigned
 * int used before on Win64, but there is no reason to keep a near-match once the header can be
 * read: XLulong is `unsigned long`, which is 32-bit here and 64-bit almost everywhere else. */
typedef ct_xlstatus (__stdcall *ct_xlSetBitrate)(ct_xlport, ct_xlaccess, unsigned long);
typedef ct_xlstatus (__stdcall *ct_xlSetOutput)(ct_xlport, ct_xlaccess, int);
typedef ct_xlstatus (__stdcall *ct_xlSetChanMode)(ct_xlport, ct_xlaccess, int, int);
typedef ct_xlstatus (__stdcall *ct_xlActivate)(ct_xlport, ct_xlaccess, unsigned int, unsigned int);
typedef ct_xlstatus (__stdcall *ct_xlDeactivate)(ct_xlport, ct_xlaccess);
typedef ct_xlstatus (__stdcall *ct_xlTransmit)(ct_xlport, ct_xlaccess, unsigned int *, void *);
typedef ct_xlstatus (__stdcall *ct_xlReceive)(ct_xlport, unsigned int *, void *);
typedef ct_xlstatus (__stdcall *ct_xlSetNotify)(ct_xlport, HANDLE *, int);
typedef char *      (__stdcall *ct_xlGetErrString)(ct_xlstatus);
/* Takes XLdriverConfig*; declared void* here so the struct can live beside the code that reads
 * it, several hundred lines down with its layout assertions. */
typedef ct_xlstatus (__stdcall *ct_xlGetDriverConfig)(void *);
typedef ct_xlstatus (__stdcall *ct_xlReqChipState)(ct_xlport, ct_xlaccess);

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
static ct_xlGetDriverConfig ct_xl_drvconfig;
static ct_xlReqChipState   ct_xl_reqchip;

static int ct_vector_loaded = 0;

/* Error frames seen and skipped. They carry no payload, so they must not reach the trace as
 * traffic — but they are the whole answer to "is this bus alive at some other bitrate": a
 * silent node on a live bus it cannot decode sees error frames and nothing else, while a dead
 * or unpowered bus is simply quiet. Discarding them without counting made those two look
 * identical, which is exactly the question a bench asks first. */
static volatile long ct_vector_errframes = 0;

/* Step-by-step reporting for the open path. Off unless asked: this is the only way to see which
 * of half a dozen XL calls quietly did not do what its return value implied. */
static int ct_vector_verbose = 0;
static void ct_vector_set_verbose(int on) { ct_vector_verbose = on; }
#define CT_VLOG(...) do { if (ct_vector_verbose) { fprintf(stderr, "  xl: " __VA_ARGS__); fflush(stderr); } } while (0)

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
/* Set when the port holding initialisation access has closed while others are still open. What
 * we knew about the channel stopped being true at that moment — another application may take
 * the access and change the rate — but the ports still running are still running, and dropping
 * the record out from under them refused their siblings for want of one. Kept for their
 * bookkeeping, closed to new arrivals. */
static int ct_vec_cfg_stale[CT_VEC_MAX_CFG];
/* Which OPEN of this channel a reference belongs to. The mask identifies a wire, not an
 * episode: when the owner closes the record is forgotten, a replacement owner can configure the
 * same wire afresh, and a secondary port left over from the previous episode then closes and
 * decrements a record it never joined — taking the live channel's count down with it, after
 * which its taps are refused. Every reference carries the generation it joined. */
static uint64_t ct_vec_cfg_gen[CT_VEC_MAX_CFG];
static uint64_t ct_vec_gen_seq = 0;
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
		ct_vec_cfg_gen[i] = ++ct_vec_gen_seq;
		ct_vec_cfg_stale[i] = 0;
	}
	ct_vec_cfg_rate[i] = rate;
	ct_vec_cfg_silent[i] = silent;
	ct_vec_cfg_owner[i] = owner;
	/* FRESH AGAIN. A record marked stale when its owner closed keeps that mark until it is
	 * forgotten, so a later port that DID win initialisation access — and therefore configured
	 * the channel itself — inherited a record saying nothing about it could be trusted, and
	 * every sibling open after it was refused. Configuring the channel is what makes the record
	 * true again. */
	ct_vec_cfg_stale[i] = 0;
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
		ct_vec_cfg_gen[i]    = ct_vec_cfg_gen[ct_vec_cfg_n];
		ct_vec_cfg_stale[i]  = ct_vec_cfg_stale[ct_vec_cfg_n];
	}
}

/* INITIALISATION ACCESS BELONGS TO A PORT, not to the channel. When the port that holds it
 * closes, XL releases that access even though our other ports on the same wire stay open — so
 * another application can take it and change the rate or the output mode, and everything we
 * remember about the channel stops being true at that moment rather than when our last port
 * goes. The record is dropped with its owner; ports still open keep running, but nothing new is
 * admitted on the strength of what we used to know. */
static void ct_vec_cfg_unref(uint64_t mask, ct_xlport port, uint64_t gen) {
	int i = ct_vec_cfg_find(mask);
	/* A port from a PREVIOUS episode of this wire has nothing to release: its record went with
	 * its owner, and the one here now belongs to somebody else. */
	if (i < 0 || ct_vec_cfg_gen[i] != gen) return;
	if (ct_vec_cfg_owner[i] == port) {
		/* The owner is going, but its siblings are not. Forgetting the record here left every
		 * still-open port's eventual close with nothing to release, and — worse — the next open
		 * on that wire was refused for want of a record while ports were live on it. Marked
		 * stale instead: existing ports keep their bookkeeping, and nothing new is admitted on
		 * what we no longer know. */
		if (--ct_vec_cfg_ports[i] > 0) {
			ct_vec_cfg_stale[i] = 1;
			ct_vec_cfg_owner[i] = CT_XL_INVALID_PORTHANDLE;
			return;
		}
		ct_vec_cfg_forget(i);
		return;
	}
	if (--ct_vec_cfg_ports[i] > 0) return;
	/* ct_vec_cfg_forget, not a second copy of it. This path had its own dense-swap that moved
	 * four of the six fields, leaving the relocated record with another entry's owner and
	 * generation — so a later close matched the wrong episode and a wire we no longer held
	 * still looked configured by us. One swap, in one place. */
	ct_vec_cfg_forget(i);
}

/* Where the library was actually found, for diagnostics. Empty until one loads. */
static char ct_vector_dll[MAX_PATH * 2] = "";

/* The XL Driver Library does NOT install onto the search path. Its installer puts the DLLs
 * under C:\Users\Public\Documents\Vector\XL Driver Library <version>\bin, so a plain
 * LoadLibrary by name finds nothing on a machine where it is perfectly well installed — which
 * is what happened on the first bench this backend met, and reads exactly like "not installed".
 *
 * We do not ship the DLL and never will: Vector's terms forbid redistributing it, which is the
 * whole reason this file resolves everything at runtime. Finding the copy the operator
 * installed is the other half of that arrangement.
 *
 * The version is in the directory name, so the newest by name wins when several are present.
 * Approximate, and stated rather than hidden: version directories sort correctly until a
 * component reaches ten, and a bench with two XL versions installed has a bigger question than
 * which one we picked. */
static HMODULE ct_vector_from_install_dir(void) {
#ifdef _WIN64
	const char *dllname = "vxlapi64.dll";
#else
	const char *dllname = "vxlapi.dll";
#endif
	char pub[MAX_PATH], pattern[MAX_PATH * 2], best[MAX_PATH], full[MAX_PATH * 2];
	WIN32_FIND_DATAA fd;
	HANDLE h;
	HMODULE m;
	DWORD n = GetEnvironmentVariableA("PUBLIC", pub, (DWORD)sizeof(pub));
	if (n == 0 || n >= sizeof(pub)) {
		strcpy(pub, "C:\\Users\\Public");
	}
	snprintf(pattern, sizeof(pattern), "%s\\Documents\\Vector\\XL Driver Library *", pub);
	best[0] = 0;
	h = FindFirstFileA(pattern, &fd);
	if (h == INVALID_HANDLE_VALUE) return NULL;
	do {
		if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
		if (strcmp(fd.cFileName, best) > 0) {
			strncpy(best, fd.cFileName, sizeof(best) - 1);
			best[sizeof(best) - 1] = 0;
		}
	} while (FindNextFileA(h, &fd));
	FindClose(h);
	if (!best[0]) return NULL;
	snprintf(full, sizeof(full), "%s\\Documents\\Vector\\%s\\bin\\%s", pub, best, dllname);
	m = LoadLibraryA(full);
	if (m) {
		strncpy(ct_vector_dll, full, sizeof(ct_vector_dll) - 1);
		ct_vector_dll[sizeof(ct_vector_dll) - 1] = 0;
	}
	return m;
}

/* 0 ok, -1 DLL missing, -2 a symbol missing. */
static int ct_vector_load_locked(void) {
	HMODULE h;
	if (ct_vector_loaded) return 0;
	/* BY NAME FIRST: a copy beside the executable, on PATH, or in System32 is a deliberate
	 * choice by whoever put it there, and it should win over whatever the installer left. */
	h = LoadLibraryA("vxlapi64.dll");
	if (h) strcpy(ct_vector_dll, "vxlapi64.dll");
	if (!h) {
		h = LoadLibraryA("vxlapi.dll"); /* 32-bit host, same ABI shape */
		if (h) strcpy(ct_vector_dll, "vxlapi.dll");
	}
	if (!h) h = ct_vector_from_install_dir();
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
	ct_xl_drvconfig  = (ct_xlGetDriverConfig)(void *)GetProcAddress(h, "xlGetDriverConfig");
	ct_xl_reqchip    = (ct_xlReqChipState)(void *)GetProcAddress(h, "xlCanRequestChipState");
	if (!ct_xl_opendrv || !ct_xl_getappl || !ct_xl_chanmask || !ct_xl_openport ||
	    !ct_xl_closeport || !ct_xl_setbitrate || !ct_xl_activate || !ct_xl_deactivate ||
	    !ct_xl_transmit || !ct_xl_receive || !ct_xl_setnotify) return -2;
	ct_vector_loaded = 1;
	return 0;
}

/* THE FIRST LOAD IS A RACE otherwise. The Discover dialog can Refresh on the UI thread while an
 * RX worker opens a channel, and both reach the "already loaded?" test before either sets it —
 * two LoadLibrary calls writing the same function-pointer table while the other reads it. The
 * flag was doing the job of a lock. */
static int ct_vector_load(void) {
	int rc;
	ct_vec_enter();
	rc = ct_vector_load_locked();
	ct_vec_leave();
	return rc;
}

/* How many error frames this process has seen since it started. */
static long ct_vector_error_frames(void) { return ct_vector_errframes; }

/* Which vxlapi the process is actually using, or "" if none loaded. */
static const char *ct_vector_dll_path(void) { return ct_vector_dll; }

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
static uint64_t ct_vector_mask_why(unsigned int app_channel, int *why, int register_app) {
	unsigned int hw_type = 0, hw_index = 0, hw_channel = 0;
	int rc;
	ct_xlstatus st;
	if (why) *why = 0;
	rc = ct_vector_load();
	if (rc != 0) { if (why) *why = rc; return 0; }          /* -1 no DLL, -2 no symbol */
	st = ct_xl_opendrv();
	if (st != 0) { if (why) *why = -(int)st; return 0; }    /* driver would not open */
	/* A FAILED LOOKUP IS NOT AN EMPTY ONE, and here the difference is destructive: the branch
	 * below REGISTERS, which writes an all-zero mapping. Merged with a transient read failure
	 * that meant an already-configured channel had its assignment cleared — by the very call
	 * that was about to report it as unassigned. Asked separately, answered separately. */
	if (ct_xl_getappl("blobly_net", app_channel, &hw_type, &hw_index, &hw_channel,
	                  CT_XL_BUS_TYPE_CAN) != 0) {
		if (why) *why = -1007;
		return 0;
	}
	if (hw_type == 0) {
		/* Registering makes the application appear in Vector Hardware Manager so the operator
		 * has something to assign hardware to — worth doing for a channel somebody ASKED to
		 * open, and not for the sixty-four this sweeps past during discovery. A dialog listing
		 * blobly_net channels 1 to 64, all unassigned, is worse than no entry at all.
		 *
		 * Safe to write here BECAUSE the lookup succeeded and said the channel is empty: the
		 * zeroes it writes are the value already there. */
		if (register_app) {
			/* REPORTED. Ignoring this told the operator the application had been "registered
			 * just now" and to go and assign it, when nothing had been written and Vector
			 * Hardware Manager would show no such entry — sending them to look for something
			 * that is not there. */
			if (!ct_xl_setappl) { if (why) *why = -1008; return 0; }
			if (ct_xl_setappl("blobly_net", app_channel, 0, 0, 0, CT_XL_BUS_TYPE_CAN) != 0) {
				if (why) *why = -1008;
				return 0;
			}
		}
		if (why) *why = -1000; /* driver fine, this channel simply has no hardware yet */
		return 0;
	}
	{
		uint64_t m = (uint64_t)ct_xl_chanmask((int)hw_type, (int)hw_index, (int)hw_channel);
		/* ASSIGNED BUT ABSENT. xlGetApplConfig hands back the saved triple whether or not the
		 * device is plugged in, and only xlGetChannelMask notices it has gone — returning zero,
		 * which used to be reported as "no hardware assigned" and sent the operator to rewrite
		 * an assignment that was perfectly correct. The adapter being unplugged is a different
		 * sentence. */
		if (!m && why) *why = -1001;
		return m;
	}
}

/* Probe only: never registers. Discovery asks about every supported channel. */
static uint64_t ct_vector_mask(unsigned int app_channel) {
	return ct_vector_mask_why(app_channel, NULL, 0);
}

/* Open, configure and activate one application channel.
 * `silent` puts the transceiver in ACK-free listen mode BEFORE the channel goes on the bus,
 * which is the only order that is safe on a live one: a channel activated normally at the
 * wrong bitrate acknowledges nothing correctly and floods error frames.
 * Returns 0, or a negative XL status. Outputs port + mask on success. */
static int ct_vector_open(unsigned int app_channel, unsigned int bitrate, int silent,
                          ct_xlport *out_port, uint64_t *out_mask, HANDLE *out_event,
                          uint64_t *out_gen) {
	ct_xlaccess mask, permission;
	ct_xlport port = CT_XL_INVALID_PORTHANDLE;
	ct_xlstatus st;
	int why = 0;
	ct_vec_enter();
	mask = (ct_xlaccess)ct_vector_mask_why(app_channel, &why, 1);
	CT_VLOG("appChannel=%u -> mask=0x%016llX (why=%d)\n", app_channel, (unsigned long long)mask, why);
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
	CT_VLOG("xlOpenPort -> st=%d port=%d permission=0x%016llX\n", (int)st, (int)port, (unsigned long long)permission);
	if (st != 0 || port == CT_XL_INVALID_PORTHANDLE) { ct_vec_leave(); return st ? -(int)st : -1001; }
	/* Init access decides whether this port may set the bitrate at all. Without it another
	 * application already owns the channel's parameters, and setting them would either fail
	 * or reconfigure a bus somebody else is using. */
	if (permission & mask) {
		st = ct_xl_setbitrate(port, mask, (unsigned long)bitrate);
		CT_VLOG("xlCanSetChannelBitrate(%u) -> st=%d\n", bitrate, (int)st);
		if (st != 0) { ct_xl_closeport(port); ct_vec_leave(); return -(int)st; }
		if (ct_xl_setoutput) {
			st = ct_xl_setoutput(port, mask, silent ? (int)CT_XL_OUTPUT_MODE_SILENT : (int)CT_XL_OUTPUT_MODE_NORMAL);
			CT_VLOG("xlCanSetChannelOutput(%s) -> st=%d\n", silent ? "SILENT" : "NORMAL", (int)st);
			/* EITHER DIRECTION. Ignoring a failed NORMAL request left the channel on whatever
			 * output mode it already had — silent, if a previous run set it — while this port
			 * recorded itself as able to transmit. send() then succeeds and the trace shows
			 * frames the transceiver never emitted, which is the quietest way for a bench to
			 * lie. Setting the mode is not optional in either direction. */
			if (st != 0) { ct_xl_closeport(port); ct_vec_leave(); return -(int)st; }
		} else {
			/* EITHER MODE, not just silence. Without this call we cannot set the output mode at
			 * all, so we cannot promise silence AND cannot undo it: a channel left silent by an
			 * earlier run would be recorded here as normal, and send() would report traffic the
			 * transceiver never emitted. Not knowing which mode the hardware is in is a reason
			 * to refuse in both directions. */
			ct_xl_closeport(port); ct_vec_leave(); return -1002;
		}
		if (ct_vec_cfg_note(mask, bitrate, silent, port) != 0) {
			ct_xl_closeport(port); ct_vec_leave(); return -1006;
		}
		ct_vec_cfg_ref(mask);
		*out_gen = ct_vec_cfg_gen[ct_vec_cfg_find(mask)];
	} else {
		/* No init access. Either we already configured this channel — a second port for a bus
		 * this process is running, which is normal and must work — or somebody else owns it. */
		int i = ct_vec_cfg_find(mask);
		if (i < 0) { ct_xl_closeport(port); ct_vec_leave(); return -1003; }
		/* STALE IS TEMPORARY, and telling it apart matters. The record goes stale when the port
		 * holding initialisation access closes while siblings are still draining — on Stop with
		 * a reader parked in recv(200), that is every restart — and it disappears by itself once
		 * they finish. Refusing it with the same code as "somebody else owns this wire" made an
		 * immediate Start fail for the new reader AND every transmit tap, and rx_loop does not
		 * retry an open, so the run sat there with neither until another Stop/Start. Its own
		 * code, so the caller can wait the moment out. */
		if (ct_vec_cfg_stale[i]) { ct_xl_closeport(port); ct_vec_leave(); return -1009; }
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
		*out_gen = ct_vec_cfg_gen[i];
	}
	/* No TX confirmations and no TX requests in the receive queue. The XL driver can deliver an
	 * event for every frame WE send, and echoes_own_sends() reports false for a vendor backend —
	 * so anything that arrived here would be filed as traffic the ECU produced. Belt and braces:
	 * the flags are filtered on read too, because an older DLL may not export this call. */
	if (ct_xl_setchanmode) {
		st = ct_xl_setchanmode(port, mask, 0, 0);
		CT_VLOG("xlCanSetChannelMode(tx=0,txrq=0) -> st=%d\n", (int)st);
	}
	if (ct_xl_setnotify(port, out_event, 1) != 0) *out_event = NULL;
	st = ct_xl_activate(port, mask, CT_XL_BUS_TYPE_CAN, CT_XL_ACTIVATE_NONE);
	CT_VLOG("xlActivateChannel -> st=%d\n", (int)st);
	if (st != 0) {
		/* The reference AND the notification handle were both taken above; drop them here rather
		 * than in ct_vector_close, which the caller never reaches for a port that failed to
		 * activate. A retry loop against a channel that will not activate leaked one Win32 event
		 * per attempt. */
		ct_vec_cfg_unref(mask, port, *out_gen);
		ct_xl_closeport(port);
		if (*out_event) { CloseHandle(*out_event); *out_event = NULL; }
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
	CT_VLOG("xlCanTransmit(id=0x%X len=%u mask=0x%016llX) -> st=%d count=%u\n",
	        (unsigned)id, (unsigned)len, (unsigned long long)mask, (int)st, count);
	if (st == 0) return 0;
	/* BACK-PRESSURE, not failure. A full transmit queue means the caller is offering frames
	 * faster than a 500 kbit/s wire can carry them, which is an ordinary thing for a replay of a
	 * busy capture to do and says nothing is wrong. Reported as its own code so the caller can
	 * wait rather than abandon the run — which is what it did, because a queue-full status was
	 * indistinguishable from a bus that had gone away. */
	if (st == CT_XL_ERR_QUEUE_IS_FULL) return -2000;
	return -(int)st;
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
	int polled = 0;
	for (;;) {
		/* AT LEAST ONE POLL, always. Checking the deadline before the first receive made
		 * recv(0) — the non-blocking poll a drain loop wants — return "nothing" without ever
		 * asking the driver, because zero milliseconds have always already elapsed. Every
		 * caller draining a queue was then paying a full millisecond per frame to get an
		 * answer the driver had ready.
		 *
		 * THE DEADLINE APPLIES TO SKIPPING TOO. Every event we drop — a non-message tag, an
		 * error frame, a confirmation of our own transmission — used to `continue` without
		 * consulting it, so a queue that stays populated (an error-frame storm, or a bus we are
		 * driving hard) let recv(200) drain for as long as the events kept coming. The caller
		 * that asked for 200 ms is a GUI receive loop or an ISO-TP timeout, and neither expects
		 * to be held. */
		if (polled && timeout_ms >= 0 && GetTickCount64() - started >= (ULONGLONG)timeout_ms) return 1;
		polled = 1;
		count = 1;
		st = ct_xl_receive(port, &count, &ev);
		if (st == 0 && count > 0) {
			if (ev.tag != CT_XL_RECEIVE_MSG) continue;
			/* An error frame carries no payload, and a TX confirmation is OUR OWN frame coming
			 * back: filing either as bus traffic puts a message on the trace nobody sent. */
			if (ev.tagData.msg.flags & CT_XL_CAN_MSG_FLAG_ERROR_FRAME) {
				InterlockedIncrement(&ct_vector_errframes);
				continue;
			}
			if (ev.tagData.msg.flags & (CT_XL_CAN_MSG_FLAG_TX_COMPLETED | CT_XL_CAN_MSG_FLAG_TX_REQUEST)) continue;
			*rtr = (ev.tagData.msg.flags & CT_XL_CAN_MSG_FLAG_REMOTE_FRAME) ? 1 : 0;
			*ext = (ev.tagData.msg.id & CT_XL_CAN_EXT_MSG_ID) ? 1 : 0;
			*id  = ev.tagData.msg.id & 0x1FFFFFFF;
			*len = (uint8_t)(ev.tagData.msg.dlc > 8 ? 8 : ev.tagData.msg.dlc);
			for (i = 0; i < 8; i++) data[i] = ev.tagData.msg.data[i];
			return 0;
		}
		if (st != CT_XL_ERR_QUEUE_IS_EMPTY && st != 0) return -(int)st;
		if (!ev_handle) {
			/* No notification object — xlSetNotification failed at open. Returning at once made
			 * recv(200) an immediate no, so the GUI's receive loop retried with no delay and
			 * pegged a core. Poll on a short sleep until the caller's deadline instead: slower
			 * than an event, and the only alternative to a busy wait. */
			if (timeout_ms < 0) { Sleep(1); continue; }
			if (GetTickCount64() - started >= (ULONGLONG)timeout_ms) return 1;
			Sleep(1);
			continue;
		}
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

/* THE CONTROLLER'S OWN VERDICT on a send that produced nothing.
 *
 * xlCanTransmit returning 0 means the frame was QUEUED, not that it reached the wire — so a
 * silent failure looks identical to a bus nobody is listening on. The error counters tell them
 * apart: a frame that went out and was never acknowledged drives txErrorCounter up and the chip
 * towards error-passive, while a frame that never left leaves both counters at rest.
 *
 * 0 ok, negative otherwise. Consumes queued events while it looks for the answer, so it belongs
 * at the END of a diagnostic run. */
static int ct_vector_chipstate(ct_xlport port, uint64_t mask, int *bus_status, int *tx_err, int *rx_err) {
	ct_xlevent ev;
	unsigned int count;
	ct_xlstatus st;
	int spins;
	if (!ct_xl_reqchip) return -1;
	st = ct_xl_reqchip(port, (ct_xlaccess)mask);
	if (st != 0) return -(int)st;
	for (spins = 0; spins < 200; spins++) {
		count = 1;
		st = ct_xl_receive(port, &count, &ev);
		if (st == 0 && count > 0 && ev.tag == CT_XL_CHIP_STATE) {
			*bus_status = ev.tagData.raw[0];
			*tx_err     = ev.tagData.raw[1];
			*rx_err     = ev.tagData.raw[2];
			return 0;
		}
		Sleep(5);
	}
	return -1;
}

static void ct_vector_close(ct_xlport port, uint64_t mask, uint64_t gen, HANDLE notify) {
	if (port == CT_XL_INVALID_PORTHANDLE) return;

	/* UNDER THE LOCK, AND BEFORE xlClosePort. A port handle is a small reusable number: closing
	 * first releases it, an open racing this call can be handed the same value and become the
	 * recorded owner, and the cleanup that followed would then delete the NEW channel's record
	 * on the strength of the old port's number. Every same-process tap after that is refused for
	 * want of a record. Releasing the record while the handle is still ours makes the identity
	 * unambiguous without having to invent generations for it. */
	ct_vec_enter();
	ct_vec_cfg_unref(mask, port, gen);
	ct_xl_deactivate(port, (ct_xlaccess)mask);
	ct_xl_closeport(port);
	/* The NOTIFICATION HANDLE is a kernel object this process owns from xlSetNotification, and
	 * nothing was returning it: every Start/Stop cycle leaked one per monitor and per transmit
	 * tap, on a GUI people leave running all day.
	 *
	 * AFTER the port is closed, not before. While the port lives the driver may still signal
	 * that object, and closing it first leaves a window where Windows can hand the same handle
	 * value to something else and the driver signals a stranger. */
	if (notify) CloseHandle(notify);
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

/* WHAT IS ACTUALLY PLUGGED IN, from xlGetDriverConfig.
 *
 * This struct was left out of the first version of this backend on purpose: reproducing forty
 * packed fields from documentation fails by reading out of bounds rather than by returning an
 * error, and there was no way to check it. It is here now because the operator's XL Driver
 * Library install ships vxlapi.h, so the layout below was compared field by field against the
 * real one and every size and offset in the assertions was MEASURED by compiling against it —
 * not deduced. The header is still not included: we cannot depend at build time on a library we
 * are forbidden to redistribute.
 *
 * Byte-packed. sizeof(XLchannelConfig) is 227, an odd number, which is the giveaway. */
#pragma pack(push, 1)
typedef struct {
	uint32_t busType;
	uint32_t bitRate;   /* the CAN arm of the union; the rest is not ours to interpret */
	uint8_t  rest[24];
} ct_xl_bus_params;

typedef struct {
	char     name[32];
	uint8_t  hwType, hwIndex, hwChannel;
	uint16_t transceiverType, transceiverState, configError;
	uint8_t  channelIndex;
	uint64_t channelMask;
	uint32_t channelCapabilities, channelBusCapabilities;
	uint8_t  isOnBus;
	uint32_t connectedBusType;
	ct_xl_bus_params busParams;
	uint32_t doNotUse, driverVersion, interfaceVersion;
	uint32_t raw_data[10];
	uint32_t serialNumber, articleNumber;
	char     transceiverName[32];
	uint32_t specialCabFlags, dominantTimeout;
	uint8_t  dominantRecessiveDelay, recessiveDominantDelay, connectionInfo, currentlyAvailableTimestamps;
	uint16_t minimalSupplyVoltage, maximalSupplyVoltage;
	uint32_t maximalBaudrate;
	uint8_t  fpgaCoreCapabilities, specialDeviceStatus;
	uint16_t channelBusActiveCapabilities, breakOffset, delimiterOffset;
	uint32_t reserved[3];
} ct_xl_channel_config;

typedef struct {
	uint32_t dllVersion;
	uint32_t channelCount;
	uint32_t reserved[10];
	ct_xl_channel_config channel[64];
} ct_xl_driver_config;
#pragma pack(pop)

_Static_assert(sizeof(ct_xl_bus_params) == 32, "XLbusParams is 32 bytes");
_Static_assert(sizeof(ct_xl_channel_config) == 227, "XLchannelConfig is 227 bytes");
_Static_assert(sizeof(ct_xl_driver_config) == 14576, "XLdriverConfig is 14576 bytes");
_Static_assert(offsetof(ct_xl_channel_config, hwType) == 32, "hwType at 32");
_Static_assert(offsetof(ct_xl_channel_config, channelIndex) == 41, "channelIndex at 41");
_Static_assert(offsetof(ct_xl_channel_config, channelMask) == 42, "channelMask at 42");
_Static_assert(offsetof(ct_xl_channel_config, connectedBusType) == 59, "connectedBusType at 59");
_Static_assert(offsetof(ct_xl_channel_config, busParams) == 63, "busParams at 63");
_Static_assert(offsetof(ct_xl_channel_config, serialNumber) == 147, "serialNumber at 147");
_Static_assert(offsetof(ct_xl_channel_config, transceiverName) == 155, "transceiverName at 155");
_Static_assert(offsetof(ct_xl_driver_config, channel) == 48, "channel array at 48");

/* One channel from the driver's own view of the bench. 0 ok, -1 unavailable, -2 out of range.
 * `name` and `transceiver` are NUL-terminated on the way out; the driver's are fixed-width. */
static int ct_vector_channel_info(int idx, char *name, int name_len, char *transceiver,
                                  int trans_len, int *hw_type, int *hw_index, int *hw_channel,
                                  unsigned int *serial, unsigned int *bus_type,
                                  unsigned int *bitrate, int *on_bus, int *trx_state) {
	static ct_xl_driver_config cfg;
	if (ct_vector_load() != 0 || !ct_xl_drvconfig) return -1;
	if (ct_xl_opendrv() != 0) return -1;
	memset(&cfg, 0, sizeof(cfg));
	if (ct_xl_drvconfig(&cfg) != 0) return -1;
	if (idx < 0 || (unsigned int)idx >= cfg.channelCount || idx >= 64) return -2;
	{
		ct_xl_channel_config *c = &cfg.channel[idx];
		int n = name_len < 33 ? name_len : 33;
		if (n > 0) { memcpy(name, c->name, n - 1); name[n - 1] = 0; }
		n = trans_len < 33 ? trans_len : 33;
		if (n > 0) { memcpy(transceiver, c->transceiverName, n - 1); transceiver[n - 1] = 0; }
		*hw_type = c->hwType; *hw_index = c->hwIndex; *hw_channel = c->hwChannel;
		*serial = c->serialNumber;
		*bus_type = c->connectedBusType;
		*bitrate = c->busParams.bitRate;
		*on_bus = c->isOnBus ? 1 : 0;
		*trx_state = (int)c->transceiverState;
	}
	return 0;
}

/* ACROSS PROCESSES, not just threads. Borrowing is read-then-write-then-restore, and two
 * diagnostics run at once interleave into a permanent change: A saves the original and assigns,
 * B saves A's assignment and assigns, A restores the original, B restores A's — leaving the
 * channel pointed somewhere nobody asked for. A named mutex is the only thing that helps; the
 * process-local lock cannot see the other copy.
 *
 * Best-effort: if the mutex cannot be created we proceed rather than refusing to run a
 * diagnostic, because the common case is one operator at one bench. */
static HANDLE ct_vec_xproc = NULL;

/* 0 got it, -1 did not. The wait used to be issued and its answer thrown away, so a second
 * diagnostic simply carried on after ten seconds and did the interleaving this lock exists to
 * prevent — and a --pair run legitimately takes longer than that. A lock whose failure is
 * ignored is a comment. */
static int ct_vector_borrow_lock(void) {
	DWORD r;
	if (!ct_vec_xproc) ct_vec_xproc = CreateMutexA(NULL, FALSE, "Local\\blobly_net_vector_borrow");
	if (!ct_vec_xproc) return 0; /* cannot create one: one operator at one bench is the norm */
	r = WaitForSingleObject(ct_vec_xproc, 60000);
	/* WAIT_ABANDONED means the holder died without releasing; the channels may be half-restored,
	 * but we own it now and refusing would leave nobody able to tidy up. */
	return (r == WAIT_OBJECT_0 || r == WAIT_ABANDONED) ? 0 : -1;
}

static void ct_vector_borrow_unlock(void) {
	if (ct_vec_xproc) ReleaseMutex(ct_vec_xproc);
}

/* What an application channel is currently pointed at, WITHOUT registering anything.
 * 0 = assigned (outputs filled), -1 = not assigned or unavailable. Needed so a test that has to
 * borrow a channel can put it back exactly as it found it. */
/* 0 = assigned, -2 = definitely not assigned, -1 = COULD NOT TELL.
 *
 * The third answer matters. Collapsing it into "not assigned" meant a transient read failure
 * looked exactly like a free channel: the caller borrowed it, and gave it back by unassigning —
 * erasing a mapping the operator had made, on the strength of a question that was never
 * answered. A borrow has to refuse when it cannot see what it is about to overwrite. */
static int ct_vector_appl_get(unsigned int app_channel, int *hw_type, int *hw_index, int *hw_channel) {
	unsigned int t = 0, i = 0, c = 0;
	if (ct_vector_load() != 0 || ct_xl_opendrv() != 0) return -1;
	if (ct_xl_getappl("blobly_net", app_channel, &t, &i, &c, CT_XL_BUS_TYPE_CAN) != 0) return -1;
	if (t == 0) return -2;
	*hw_type = (int)t; *hw_index = (int)i; *hw_channel = (int)c;
	return 0;
}

/* Point one of OUR application channels at a specific piece of hardware, the way Vector
 * Hardware Manager would. Writes only under the name "blobly_net", so it cannot disturb another
 * application's assignment. 0 ok, negative XL status. */
static int ct_vector_assign(unsigned int app_channel, int hw_type, int hw_index, int hw_channel) {
	ct_xlstatus st;
	if (ct_vector_load() != 0) return -1;
	if (ct_xl_opendrv() != 0) return -2;
	if (!ct_xl_setappl) return -3;
	st = ct_xl_setappl("blobly_net", app_channel, (unsigned int)hw_type, (unsigned int)hw_index,
	                   (unsigned int)hw_channel, CT_XL_BUS_TYPE_CAN);
	return st == 0 ? 0 : -(int)st;
}

/* Ask the driver which (hwType, hwIndex, hwChannel) triples resolve to a real channel.
 * xlGetChannelMask is a pure lookup that returns 0 for hardware that is not there, so sweeping
 * it needs no table of device types to keep up to date — the driver is the authority on what is
 * plugged in, and asking it cannot be wrong the way a hardcoded list goes stale. */
static int ct_vector_probe(int idx, int *hw_type, int *hw_index, int *hw_channel, uint64_t *mask) {
	int t, i, c, n = 0;
	if (ct_vector_load() != 0) return -1;
	if (ct_xl_opendrv() != 0) return -1;
	for (t = 0; t < 256; t++)
		for (i = 0; i < 4; i++)
			for (c = 0; c < 8; c++) {
				uint64_t m = (uint64_t)ct_xl_chanmask(t, i, c);
				if (!m) continue;
				if (n == idx) {
					*hw_type = t; *hw_index = i; *hw_channel = c; *mask = m;
					return 0;
				}
				n++;
			}
	return -1;
}

/* Is an application channel assigned to hardware? For discovery. */
static int ct_vector_present(unsigned int app_channel) {
	return ct_vector_mask(app_channel) != 0;
}

#endif /* CT_VECTOR_SHIM_H */
