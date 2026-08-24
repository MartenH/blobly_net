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
/* V4 = CAN-FD, and it is not a superset of V3 that a classic port could harmlessly ask for: the
 * event encoding differs, so a V4 port MUST be read with xlCanReceive and written with
 * xlCanTransmitEx, and a V3 port with xlReceive/xlCanTransmit. Mixing them reads one struct's
 * bytes through the other's layout. Which version a port was opened with therefore travels with
 * the port (ct_vector_open's `fd`, VectorBus.fd) rather than being decided per call. */
#define CT_XL_INTERFACE_VERSION_V4 4
/* rxQueueSize is EVENTS for V3 and BYTES for V4 — the same argument with two units. 256 events
 * is what the classic port asks for; 256 BYTES would be below the library's own minimum
 * (RX_FIFO_CANFD_QUEUE_SIZE_MIN, 8192) and is rejected. 64 KiB holds ~512 maximum-size FD
 * events, which is the same order of buffering the classic port gets. */
#define CT_XL_RX_QUEUE_EVENTS     256
#define CT_XL_RX_QUEUE_BYTES_FD   65536
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

/* ---- CAN-FD (XL interface V4) ----------------------------------------------------------
 *
 * A SEPARATE SET OF STRUCTURES, not flags on the classic ones. vxlapi.h declares these under
 * `#pragma pack(8)` while XLevent is packed to 1 — the reason the classic block above can
 * assert both packings agree is that every one of its members already sits on its natural
 * offset, which is NOT true here (XLcanRxEvent has 64-bit members after an odd run of 16-bit
 * ones). So these are declared pack(8) to match the header rather than folded into the block
 * above, and the assertions below are the check that the two agree.
 *
 * The header states two of the three sizes itself — XL_CANFD_RX_EVENT_HEADER_SIZE 32 and
 * XL_CANFD_MAX_EVENT_SIZE 128 — so the RX assertions test our layout against the library's own
 * arithmetic, not merely against a number retyped from the same place. */
#define CT_XL_CAN_MAX_DATA_LEN        64
#define CT_XL_CANFD_MAX_EVENT_SIZE   128
#define CT_XL_CANFD_RX_HEADER_SIZE    32
/* Event tags on a V4 port. RX_OK and TX_OK carry the same XL_CAN_EV_RX_MSG payload — a TX_OK is
 * this port's own confirmation, which the classic path drops via the TX_COMPLETED flag and this
 * one drops by tag. */
#define CT_XL_CAN_EV_TAG_RX_OK      0x0400
#define CT_XL_CAN_EV_TAG_RX_ERROR   0x0401
#define CT_XL_CAN_EV_TAG_TX_ERROR   0x0402
#define CT_XL_CAN_EV_TAG_TX_REQUEST 0x0403
#define CT_XL_CAN_EV_TAG_TX_OK      0x0404
#define CT_XL_CAN_EV_TAG_CHIP_STATE 0x0409
#define CT_XL_CAN_EV_TAG_TX_MSG     0x0440
/* Transmit flags (XLcanTxEvent::XL_CAN_TX_MSG::msgFlags). EDL is what makes a frame FD at all;
 * BRS additionally switches to the data bitrate for the payload. The library refuses EDL with
 * RTR (XL_ERR_EDL_RTR) and BRS without EDL (XL_ERR_EDL_NOT_SET), so both combinations are
 * rejected here rather than sent to be refused. */
#define CT_XL_CAN_TXMSG_FLAG_EDL 0x0001
#define CT_XL_CAN_TXMSG_FLAG_BRS 0x0002
#define CT_XL_CAN_TXMSG_FLAG_RTR 0x0010
/* Receive flags (XLcanRxEvent::XL_CAN_EV_RX_MSG::msgFlags). ESI is the transmitting node saying
 * it is error-passive — carried up because it is a fact about the OTHER end that no local
 * counter reports. */
#define CT_XL_CAN_RXMSG_FLAG_EDL 0x0001
#define CT_XL_CAN_RXMSG_FLAG_BRS 0x0002
#define CT_XL_CAN_RXMSG_FLAG_ESI 0x0004
#define CT_XL_CAN_RXMSG_FLAG_RTR 0x0010
#define CT_XL_CAN_RXMSG_FLAG_EF  0x0200

#pragma pack(push, 8)
typedef struct {
	unsigned int  arbitrationBitRate;
	unsigned int  sjwAbr;
	unsigned int  tseg1Abr;
	unsigned int  tseg2Abr;
	unsigned int  dataBitRate;
	unsigned int  sjwDbr;
	unsigned int  tseg1Dbr;
	unsigned int  tseg2Dbr;
	unsigned char reserved;     /* has to be zero */
	unsigned char options;      /* CANFD_CONFOPT_* */
	unsigned char reserved1[2]; /* has to be zero */
	unsigned int  reserved2;    /* has to be zero */
} ct_xl_canfd_conf;

typedef struct {
	unsigned int  canId;
	unsigned int  msgFlags;
	unsigned char dlc;
	unsigned char reserved[7];
	unsigned char data[CT_XL_CAN_MAX_DATA_LEN];
} ct_xl_can_tx_msg;

typedef struct {
	unsigned short tag;
	unsigned short transId;
	unsigned char  channelIndex; /* "internal has to be 0" */
	unsigned char  reserved[3];
	union {
		ct_xl_can_tx_msg canMsg;
	} tagData;
} ct_xl_can_tx_event;

typedef struct {
	unsigned int   canId;
	unsigned int   msgFlags;
	unsigned int   crc;
	unsigned char  reserved1[12];
	unsigned short totalBitCnt;
	unsigned char  dlc;
	unsigned char  reserved[5];
	unsigned char  data[CT_XL_CAN_MAX_DATA_LEN];
} ct_xl_can_ev_rx_msg;

typedef struct {
	unsigned char busStatus;
	unsigned char txErrorCounter;
	unsigned char rxErrorCounter;
	unsigned char reserved;
	unsigned int  reserved0;
} ct_xl_can_ev_chip_state;

typedef struct {
	unsigned int   size; /* overall size of the complete event */
	unsigned short tag;
	unsigned short channelIndex;
	unsigned int   userHandle;
	unsigned short flagsChip;
	unsigned short reserved0;
	uint64_t       reserved1;
	uint64_t       timeStampSync;
	union {
		unsigned char           raw[CT_XL_CANFD_MAX_EVENT_SIZE - CT_XL_CANFD_RX_HEADER_SIZE];
		ct_xl_can_ev_rx_msg     canRxOkMsg;
		ct_xl_can_ev_rx_msg     canTxOkMsg;
		ct_xl_can_ev_chip_state canChipState;
	} tagData;
} ct_xl_can_rx_event;
#pragma pack(pop)

_Static_assert(sizeof(ct_xl_canfd_conf) == 40, "XLcanFdConf must be 40 bytes");
_Static_assert(sizeof(ct_xl_can_tx_msg) == 80, "XL_CAN_TX_MSG must be 80 bytes");
_Static_assert(sizeof(ct_xl_can_tx_event) == 88, "XLcanTxEvent must be 88 bytes");
/* The header's own two constants, which is what makes these more than a retyped number: the
 * union is sized as MAX_EVENT_SIZE - RX_HEADER_SIZE, so a header whose members did not add up
 * to 32 would fail the first of these rather than silently shifting every payload. */
_Static_assert(offsetof(ct_xl_can_rx_event, tagData) == CT_XL_CANFD_RX_HEADER_SIZE,
               "XLcanRxEvent header must be 32 bytes");
_Static_assert(sizeof(ct_xl_can_ev_rx_msg) == CT_XL_CANFD_MAX_EVENT_SIZE - CT_XL_CANFD_RX_HEADER_SIZE,
               "XL_CAN_EV_RX_MSG must fill the event payload");
_Static_assert(sizeof(ct_xl_can_rx_event) == CT_XL_CANFD_MAX_EVENT_SIZE,
               "XLcanRxEvent must be 128 bytes");
_Static_assert(offsetof(ct_xl_can_ev_rx_msg, data) == 32, "FD receive payload must start at 32");
_Static_assert(offsetof(ct_xl_can_tx_msg, data) == 16, "FD transmit payload must start at 16");

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
/* CAN-FD. Resolved like the rest and allowed to be absent: an older XL library has a working
 * classic backend and no FD, and that must stay a refused FD open rather than a failed load. */
typedef ct_xlstatus (__stdcall *ct_xlCanFdSetConfiguration)(ct_xlport, ct_xlaccess, ct_xl_canfd_conf *);
typedef ct_xlstatus (__stdcall *ct_xlCanTransmitEx)(ct_xlport, ct_xlaccess, unsigned int, unsigned int *, ct_xl_can_tx_event *);
typedef ct_xlstatus (__stdcall *ct_xlCanReceive)(ct_xlport, ct_xl_can_rx_event *);

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
static ct_xlCanFdSetConfiguration ct_xl_fdsetconf;
static ct_xlCanTransmitEx  ct_xl_transmitex;
static ct_xlCanReceive     ct_xl_canreceive;

/* DLC <-> length, the FD way. Above eight bytes a CAN-FD frame does not carry its length: it
 * carries a 4-bit CODE for one of eight discrete sizes, so 12, 16, 20, 24, 32, 48 and 64 are
 * the only payloads that exist and anything between them must be padded up to the next one.
 * CANFD_GET_NUM_DATABYTES in vxlapi.h is the receive direction of exactly this table. */
static uint8_t ct_fd_len_from_dlc(uint8_t dlc, int edl, int rtr) {
	if (rtr) return 0;
	if (dlc < 9) return dlc;
	if (!edl) return 8; /* a classic frame cannot exceed 8 whatever its DLC nibble says */
	switch (dlc) {
	case 9:  return 12;
	case 10: return 16;
	case 11: return 20;
	case 12: return 24;
	case 13: return 32;
	case 14: return 48;
	default: return 64;
	}
}

/* The transmit direction: the DLC code that carries at least `len` bytes, and the padded length
 * that code actually puts on the wire. Returns 0xFF for a length no FD frame can hold.
 *
 * PADDING IS REPORTED, not applied silently: a 9-byte payload goes out as a 12-byte frame, and
 * the caller has to know that or the trace records nine bytes against a frame carrying twelve —
 * the same disagreement between record and wire that the classic path refuses a 9-byte frame to
 * avoid. ct_vector_write hands the padded length back so the caller can decide. */
static uint8_t ct_fd_dlc_for_len(uint8_t len, uint8_t *padded) {
	static const uint8_t sizes[] = {12, 16, 20, 24, 32, 48, 64};
	int i;
	if (len <= 8) { *padded = len; return len; }
	for (i = 0; i < 7; i++) {
		if (len <= sizes[i]) { *padded = sizes[i]; return (uint8_t)(9 + i); }
	}
	*padded = 0;
	return 0xFF;
}

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
/* PINNED LIKE THE BITRATE, and for the same reason: an FD channel and a classic one are two
 * different configurations of one transceiver, and the ports open on it decide which. A second
 * port asking for the other is refused (-1011) rather than joining a channel that is not running
 * the protocol it thinks it is — which would read every FD frame's payload through the classic
 * event layout. The data bitrate is pinned separately (-1012) because two ports can agree that
 * the wire is FD and still disagree about the rate its payload phase runs at. */
static int ct_vec_cfg_fd[CT_VEC_MAX_CFG];
static unsigned int ct_vec_cfg_dbr[CT_VEC_MAX_CFG];
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
static int ct_vec_cfg_note(uint64_t mask, unsigned int rate, int silent, ct_xlport owner,
                           int fd, unsigned int dbr) {
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
	ct_vec_cfg_fd[i] = fd;
	ct_vec_cfg_dbr[i] = dbr;
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
		/* MOVED WITH THE REST. Left out of this compaction, an FD record's fd/dbr would stay
		 * behind on a row now describing a different wire — and the pin check below would then
		 * compare a new channel's request against the departed channel's protocol. */
		ct_vec_cfg_fd[i]     = ct_vec_cfg_fd[ct_vec_cfg_n];
		ct_vec_cfg_dbr[i]    = ct_vec_cfg_dbr[ct_vec_cfg_n];
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
	ct_xl_fdsetconf  = (ct_xlCanFdSetConfiguration)(void *)GetProcAddress(h, "xlCanFdSetConfiguration");
	ct_xl_transmitex = (ct_xlCanTransmitEx)(void *)GetProcAddress(h, "xlCanTransmitEx");
	ct_xl_canreceive = (ct_xlCanReceive)(void *)GetProcAddress(h, "xlCanReceive");
	/* NOT IN THE REQUIRED SET. The three FD symbols are optional on purpose: a library too old to
	 * have them still drives classic CAN correctly, and failing the whole load would take a
	 * working backend away over a feature the project may not use. An FD OPEN refuses instead
	 * (-1010), which names the missing capability where it is actually wanted. */
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
                          uint64_t *out_gen, int fd, unsigned int dbitrate,
                          unsigned int a_tseg1, unsigned int a_tseg2, unsigned int a_sjw,
                          unsigned int d_tseg1, unsigned int d_tseg2, unsigned int d_sjw) {
	ct_xlaccess mask, permission;
	ct_xlport port = CT_XL_INVALID_PORTHANDLE;
	ct_xlstatus st;
	int why = 0;
	ct_vec_enter();
	mask = (ct_xlaccess)ct_vector_mask_why(app_channel, &why, 1);
	/* AFTER the mask lookup, which is what loads the library — the FD entry points are NULL until
	 * something has resolved them, so this test run first would refuse every FD open on a machine
	 * whose library has them. Refused here, before a port exists: the classic path would satisfy
	 * an FD request WRONGLY — a channel configured for classic CAN, ports opened V3, and every
	 * 64-byte frame refused one at a time at send() with nothing saying the wire was never FD. */
	if (fd && (!ct_xl_fdsetconf || !ct_xl_transmitex || !ct_xl_canreceive)) {
		ct_vec_leave();
		return -1010;
	}
	CT_VLOG("appChannel=%u -> mask=0x%016llX (why=%d)\n", app_channel, (unsigned long long)mask, why);
	if (!mask) { ct_vec_leave(); return why ? why : -1000; } /* the caller distinguishes these; see vector_windows.v */
	/* permissionMask is IN/OUT: on the way IN it asks for INIT ACCESS on these channels, and on
	 * the way OUT it says which were granted. Passing 0 asks for init access on nothing, so the
	 * bitrate below is never applied — the channel keeps whatever rate the last application left
	 * on it — and xlCanSetChannelOutput is refused for want of access, which fails every silent
	 * open. Asking for the channel we are opening is what the XL examples do and what makes the
	 * two calls after this one mean anything. */
	permission = mask;
	/* THE PORT'S INTERFACE VERSION IS THE PROTOCOL, and the queue size argument changes units with
	 * it (events for V3, bytes for V4). Both travel together here so the two can never disagree —
	 * a V4 port with a 256-BYTE queue is below the library's minimum and refuses to open, which
	 * would read as "the adapter would not open". */
	st = ct_xl_openport(&port, "blobly_net", mask, &permission,
	                    fd ? CT_XL_RX_QUEUE_BYTES_FD : CT_XL_RX_QUEUE_EVENTS,
	                    fd ? CT_XL_INTERFACE_VERSION_V4 : CT_XL_INTERFACE_VERSION,
	                    CT_XL_BUS_TYPE_CAN);
	CT_VLOG("xlOpenPort(v%d) -> st=%d port=%d permission=0x%016llX\n",
	        fd ? 4 : 3, (int)st, (int)port, (unsigned long long)permission);
	if (st != 0 || port == CT_XL_INVALID_PORTHANDLE) { ct_vec_leave(); return st ? -(int)st : -1001; }
	/* Init access decides whether this port may set the bitrate at all. Without it another
	 * application already owns the channel's parameters, and setting them would either fail
	 * or reconfigure a bus somebody else is using. */
	if (permission & mask) {
		if (fd) {
			/* ONE CALL FOR BOTH PHASES, and xlCanSetChannelBitrate is not part of it: mixing the
			 * classic bitrate call with the FD configuration leaves the arbitration phase set
			 * twice, the second time from segments the first knew nothing about.
			 *
			 * THE SEGMENTS ARE REQUIRED. XLcanFdConf has no BRP field and no "just give me this
			 * bitrate" form — the driver derives the prescaler from the rate and the segment
			 * count, so (1 + tseg1 + tseg2) has to divide the controller clock by the rate
			 * exactly or the call is refused. That is why they come in from the caller: the
			 * arithmetic is pure and belongs where it can be tested (vector_fd_timing).
			 *
			 * A SET PER PHASE, which is how XLcanFdConf is shaped and the only thing that works.
			 * Sharing one quanta count between the phases refuses pairs the hardware can do —
			 * 800k/5M is exact at 20 quanta for arbitration and 16 for data, with no usable
			 * common count (codex #181 r3). The two phases still aim at the same sample-point
			 * RATIO; they simply reach it with their own count and their own prescaler. */
			ct_xl_canfd_conf conf;
			memset(&conf, 0, sizeof(conf));
			conf.arbitrationBitRate = bitrate;
			conf.sjwAbr = a_sjw;
			conf.tseg1Abr = a_tseg1;
			conf.tseg2Abr = a_tseg2;
			conf.dataBitRate = dbitrate;
			conf.sjwDbr = d_sjw;
			conf.tseg1Dbr = d_tseg1;
			conf.tseg2Dbr = d_tseg2;
			st = ct_xl_fdsetconf(port, mask, &conf);
			CT_VLOG("xlCanFdSetConfiguration(arb=%u [%u/%u/%u] dbr=%u [%u/%u/%u]) -> st=%d\n",
			        bitrate, a_tseg1, a_tseg2, a_sjw, dbitrate, d_tseg1, d_tseg2, d_sjw, (int)st);
			if (st != 0) { ct_xl_closeport(port); ct_vec_leave(); return -(int)st; }
		} else {
			st = ct_xl_setbitrate(port, mask, (unsigned long)bitrate);
			CT_VLOG("xlCanSetChannelBitrate(%u) -> st=%d\n", bitrate, (int)st);
			if (st != 0) { ct_xl_closeport(port); ct_vec_leave(); return -(int)st; }
		}
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
		if (ct_vec_cfg_note(mask, bitrate, silent, port, fd, dbitrate) != 0) {
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
		/* THE PROTOCOL, before the rate its payload phase runs at. This port has ALREADY been
		 * opened at whichever interface version `fd` asked for, and that is the half a sibling
		 * cannot recover from by agreeing later: a V4 port on a channel configured classic reads
		 * every frame through the wrong event layout, and a V3 port on an FD channel silently
		 * truncates. Refused rather than joined. */
		if (fd != ct_vec_cfg_fd[i]) { ct_xl_closeport(port); ct_vec_leave(); return -1011; }
		if (fd && ct_vec_cfg_dbr[i] != dbitrate) { ct_xl_closeport(port); ct_vec_leave(); return -1012; }
		ct_vec_cfg_ports[i]++;
		*out_gen = ct_vec_cfg_gen[i];
	}
	/* No TX confirmations and no TX requests in the receive queue: the XL driver can deliver an
	 * event for every frame WE send on THIS port, and a confirmation is not bus traffic. Belt and
	 * braces: the flags are filtered on read too, because an older DLL may not export this call.
	 *
	 * This covers only the TRANSMITTING port's own confirmations. A frame sent on one port of a
	 * channel still reaches the OTHER ports on it as a plain RECEIVE_MSG with no TX flag, which
	 * no filter here can recognise — and the app's monitor is a different port from its transmit
	 * taps. That copy is caught one layer up instead: echoes_own_sends() answers TRUE for
	 * `vector:` (#139), so the emission is registered with modules/wiretap and the monitor claims
	 * its own echo rather than filing it as the device under test's. */
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

/* Transmit on a V4 (CAN-FD) port. 0 ok, negative XL status on failure, -2000 for a full queue.
 *
 * `fd` is per FRAME, not per port: an FD-configured channel carries classic frames too — EDL
 * clear and at most eight bytes — and a rest bus of classic messages with one FD diagnostic
 * stream is the ordinary case rather than an exotic one. `*out_len` reports the length the wire
 * will actually carry, which differs from `len` whenever FD padding rounds a payload up to the
 * next legal size (see ct_fd_dlc_for_len). */
static int ct_vector_write_fd(ct_xlport port, uint64_t mask, uint32_t id, uint8_t len,
                              const uint8_t *data, int ext, int rtr, int fd, int brs,
                              uint8_t *out_len) {
	ct_xl_can_tx_event ev;
	unsigned int sent = 0;
	uint8_t padded = 0, dlc;
	int i;
	ct_xlstatus st;
	if (out_len) *out_len = len;
	/* THE LIBRARY'S OWN TWO REFUSALS, made here where they can be explained. XL_ERR_EDL_RTR and
	 * XL_ERR_EDL_NOT_SET come back as bare status numbers from a transmit that has already been
	 * recorded as attempted; as arguments they are a configuration mistake with a name. */
	if (fd && rtr) return -2001;
	if (brs && !fd) return -2002;
	dlc = ct_fd_dlc_for_len(len, &padded);
	if (dlc == 0xFF) return -2003;
	if (!fd && len > 8) return -2003;
	memset(&ev, 0, sizeof(ev));
	ev.tag = CT_XL_CAN_EV_TAG_TX_MSG;
	ev.tagData.canMsg.canId = ext ? (id | CT_XL_CAN_EXT_MSG_ID) : id;
	ev.tagData.canMsg.dlc = dlc;
	ev.tagData.canMsg.msgFlags = (fd ? CT_XL_CAN_TXMSG_FLAG_EDL : 0) |
	                             (brs ? CT_XL_CAN_TXMSG_FLAG_BRS : 0) |
	                             (rtr ? CT_XL_CAN_TXMSG_FLAG_RTR : 0);
	for (i = 0; i < (int)padded && i < len; i++) ev.tagData.canMsg.data[i] = data[i];
	/* The pad bytes stay zero from the memset above. Which value they carry is not specified by
	 * CAN FD, and zero is what every other tool on a bench shows. */
	st = ct_xl_transmitex(port, (ct_xlaccess)mask, 1, &sent, &ev);
	CT_VLOG("xlCanTransmitEx(id=0x%X len=%u dlc=%u fd=%d brs=%d) -> st=%d sent=%u\n",
	        (unsigned)id, (unsigned)padded, (unsigned)dlc, fd, brs, (int)st, sent);
	if (st == 0) {
		/* ACCEPTED IS NOT SENT. xlCanTransmitEx reports how many of the events it took, and
		 * taking none while returning success is exactly the back-pressure case the classic path
		 * gets as a status code — treated the same way rather than reported as a frame that went
		 * out. */
		if (sent == 0) return -2000;
		if (out_len) *out_len = padded;
		return 0;
	}
	if (st == CT_XL_ERR_QUEUE_IS_FULL) return -2000;
	return -(int)st;
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
/* ONE EVENT off a V3 port. Split out of the loop below so that the FD port's decoder can sit
 * beside it and the deadline, the notification wait and the busy-poll fallback stay in ONE place.
 * Every one of those has its own hard-won comment in the loop; a second copy for FD would be the
 * same policy in two files' worth of code, differing the first time one of them was fixed.
 *
 * THREE OUTCOMES, and the third is not a detail:
 *   0  a frame, in the out-parameters
 *   1  the queue is EMPTY — there is nothing to do but wait for the notification
 *   2  an event was taken and it was not bus traffic — poll AGAIN, do not wait
 *   <0 an XL status
 * Collapsing 1 and 2 into one "nothing" is a stall: the notification is auto-reset, so after
 * consuming a chip-state event whose signal has already been taken, a wait can block with
 * decodable frames sitting in the queue behind it. The loop below acts on the difference. */
static int ct_vector_decode_v3(ct_xlport port, uint32_t *id, uint8_t *len, uint8_t *data,
                               int *ext, int *rtr, int *fd, int *brs, int *esi,
                               int *chip_status) {
	ct_xlevent ev;
	unsigned int count = 1;
	int i;
	ct_xlstatus st = ct_xl_receive(port, &count, &ev);
	if (st != 0 || count == 0) {
		if (st != CT_XL_ERR_QUEUE_IS_EMPTY && st != 0) return -(int)st;
		return 1;
	}
	/* A chip-state reply riding the same queue: capture it for the health latch
	 * instead of discarding it. The old helper that DRAINED the queue hunting for
	 * this event threw away data frames mid-run — health must ride the stream the
	 * reader is already emptying, never compete with it (self-review). */
	if (ev.tag == CT_XL_CHIP_STATE) {
		if (chip_status) *chip_status = ev.tagData.raw[0];
		return 2;
	}
	if (ev.tag != CT_XL_RECEIVE_MSG) return 2;
	/* An error frame carries no payload, and a TX confirmation is OUR OWN frame coming
	 * back: filing either as bus traffic puts a message on the trace nobody sent. */
	if (ev.tagData.msg.flags & CT_XL_CAN_MSG_FLAG_ERROR_FRAME) {
		InterlockedIncrement(&ct_vector_errframes);
		return 2;
	}
	if (ev.tagData.msg.flags & (CT_XL_CAN_MSG_FLAG_TX_COMPLETED | CT_XL_CAN_MSG_FLAG_TX_REQUEST)) return 2;
	*rtr = (ev.tagData.msg.flags & CT_XL_CAN_MSG_FLAG_REMOTE_FRAME) ? 1 : 0;
	*ext = (ev.tagData.msg.id & CT_XL_CAN_EXT_MSG_ID) ? 1 : 0;
	*id  = ev.tagData.msg.id & 0x1FFFFFFF;
	*len = (uint8_t)(ev.tagData.msg.dlc > 8 ? 8 : ev.tagData.msg.dlc);
	for (i = 0; i < 8; i++) data[i] = ev.tagData.msg.data[i];
	/* A V3 port cannot receive an FD frame at all, so these are facts and not defaults. */
	*fd = 0;
	*brs = 0;
	*esi = 0;
	return 0;
}

/* The same, off a V4 (CAN-FD) port. Same return contract, and the same rule about what is not
 * bus traffic — expressed by TAG here, where the classic path reads flags. */
static int ct_vector_decode_v4(ct_xlport port, uint32_t *id, uint8_t *len, uint8_t *data,
                               int *ext, int *rtr, int *fd, int *brs, int *esi,
                               int *chip_status) {
	ct_xl_can_rx_event ev;
	int i;
	uint8_t n;
	ct_xlstatus st;
	memset(&ev, 0, sizeof(ev));
	st = ct_xl_canreceive(port, &ev);
	if (st != 0) {
		if (st != CT_XL_ERR_QUEUE_IS_EMPTY) return -(int)st;
		return 1;
	}
	if (ev.tag == CT_XL_CAN_EV_TAG_CHIP_STATE) {
		if (chip_status) *chip_status = ev.tagData.canChipState.busStatus;
		return 2;
	}
	/* AN ERROR IS COUNTED, NOT REPORTED, exactly as on the classic port — and on a V4 port it
	 * arrives as its own tag rather than a flag on a message. Counting both directions: a bus
	 * running FD at a data rate this channel has wrong produces TX errors on what we send and RX
	 * errors on what we hear, and either one is the answer to "why is nothing decoding". */
	if (ev.tag == CT_XL_CAN_EV_TAG_RX_ERROR || ev.tag == CT_XL_CAN_EV_TAG_TX_ERROR) {
		InterlockedIncrement(&ct_vector_errframes);
		return 2;
	}
	/* TX_OK is this port's own confirmation and TX_REQUEST its own queued frame; neither is
	 * traffic somebody else put on the wire. The classic path drops the same two by flag. */
	if (ev.tag != CT_XL_CAN_EV_TAG_RX_OK) return 2;
	if (ev.tagData.canRxOkMsg.msgFlags & CT_XL_CAN_RXMSG_FLAG_EF) {
		InterlockedIncrement(&ct_vector_errframes);
		return 2;
	}
	*rtr = (ev.tagData.canRxOkMsg.msgFlags & CT_XL_CAN_RXMSG_FLAG_RTR) ? 1 : 0;
	*fd  = (ev.tagData.canRxOkMsg.msgFlags & CT_XL_CAN_RXMSG_FLAG_EDL) ? 1 : 0;
	*brs = (ev.tagData.canRxOkMsg.msgFlags & CT_XL_CAN_RXMSG_FLAG_BRS) ? 1 : 0;
	*esi = (ev.tagData.canRxOkMsg.msgFlags & CT_XL_CAN_RXMSG_FLAG_ESI) ? 1 : 0;
	*ext = (ev.tagData.canRxOkMsg.canId & CT_XL_CAN_EXT_MSG_ID) ? 1 : 0;
	*id  = ev.tagData.canRxOkMsg.canId & 0x1FFFFFFF;
	/* THROUGH THE TABLE, not the raw nibble. Above eight bytes the DLC is a code for one of eight
	 * sizes, so using it as a length would report a 64-byte frame as fifteen bytes long. */
	n = ct_fd_len_from_dlc(ev.tagData.canRxOkMsg.dlc, *fd, *rtr);
	/* EXCEPT FOR RTR, WHERE THE DLC IS THE MESSAGE. ct_fd_len_from_dlc answers vxlapi's own
	 * question — how many data bytes this event carries — and for a remote request that is
	 * correctly zero, because a remote frame has no payload. But this layer's CanFrame represents
	 * an RTR's REQUESTED length as a zero-filled `data` of that length, which is what the classic
	 * decoder returns and what ct_vector_write stamps on the way out. Zeroing it here made one
	 * frame decode two different ways depending only on which interface version the receiving
	 * port happened to be opened with: an RTR for 8 bytes came back as 8 on a classic port and 0
	 * on an FD one, so a replay lost the requested length and wiretap could not match the echo to
	 * the request it had recorded. The bytes are still never READ as payload — they are zero from
	 * the memset (codex #181 r2).
	 *
	 * An FD frame cannot be remote at all (EDL with RTR is refused both here and by the library),
	 * so this is always a classic DLC and cannot exceed 8. */
	if (*rtr) {
		n = ev.tagData.canRxOkMsg.dlc > 8 ? 8 : ev.tagData.canRxOkMsg.dlc;
	}
	if (n > CT_XL_CAN_MAX_DATA_LEN) n = CT_XL_CAN_MAX_DATA_LEN;
	*len = n;
	for (i = 0; i < (int)n; i++) data[i] = ev.tagData.canRxOkMsg.data[i];
	return 0;
}

static int ct_vector_read(ct_xlport port, HANDLE ev_handle, uint32_t *id, uint8_t *len,
                          uint8_t *data, int *ext, int *rtr, int timeout_ms, int *chip_status,
                          int port_is_fd, int *fd, int *brs, int *esi) {
	if (chip_status) *chip_status = -1; /* -1 = no chip-state event seen this call */
	DWORD waited;
	int rc;
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
		/* WHICH DECODER IS THE PORT'S, not the frame's. The interface version a port was opened
		 * with decides the event encoding on its queue, so this cannot be chosen per event —
		 * reading a V4 queue with xlReceive returns whatever the first 48 bytes of a 128-byte
		 * event happen to look like. */
		rc = port_is_fd
		     ? ct_vector_decode_v4(port, id, len, data, ext, rtr, fd, brs, esi, chip_status)
		     : ct_vector_decode_v3(port, id, len, data, ext, rtr, fd, brs, esi, chip_status);
		if (rc == 0) return 0;
		if (rc < 0) return rc;
		/* AN EVENT WAS TAKEN AND SKIPPED: poll again rather than wait. The notification is
		 * auto-reset, so its signal for this event has already been consumed — waiting here would
		 * block behind frames that are in the queue right now. The deadline at the top of the loop
		 * is what stops a queue that keeps producing skippable events from holding the caller. */
		if (rc == 2) continue;
		/* rc == 1: the queue really is empty, and waiting is the whole point. */
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
/* Fire-and-forget chip-state request: the reply arrives through the port's event queue and
 * ct_vector_read captures it into the caller's latch. NEVER reads the queue itself — that
 * is the reader's, and competing with it loses trace frames. */
static int ct_vector_reqchip(ct_xlport port, uint64_t mask) {
	if (!ct_xl_reqchip) return -1;
	return ct_xl_reqchip(port, (ct_xlaccess)mask) == 0 ? 0 : -1;
}

/* THE PORT'S OWN RECEIVE API, exactly as ct_vector_read chooses one. A V4 port's queue carries
 * 128-byte events with a different header, so reading it with xlReceive into a 48-byte ct_xlevent
 * interprets one struct's bytes through the other's layout — the tag never matches, the loop spins
 * out its 200 attempts and reports "the controller did not report its state". That is the generic
 * failure, so on an FD bench the one diagnostic that separates an unacknowledged frame from a
 * wiring fault was unavailable precisely when a run had produced no traffic (codex #181 r6). */
static int ct_vector_chipstate(ct_xlport port, uint64_t mask, int *bus_status, int *tx_err,
                               int *rx_err, int port_is_fd) {
	ct_xlevent ev;
	ct_xl_can_rx_event fdev;
	unsigned int count;
	ct_xlstatus st;
	int spins;
	if (!ct_xl_reqchip) return -1;
	if (port_is_fd && !ct_xl_canreceive) return -1;
	st = ct_xl_reqchip(port, (ct_xlaccess)mask);
	if (st != 0) return -(int)st;
	for (spins = 0; spins < 200; spins++) {
		if (port_is_fd) {
			memset(&fdev, 0, sizeof(fdev));
			st = ct_xl_canreceive(port, &fdev);
			if (st == 0 && fdev.tag == CT_XL_CAN_EV_TAG_CHIP_STATE) {
				*bus_status = fdev.tagData.canChipState.busStatus;
				*tx_err     = fdev.tagData.canChipState.txErrorCounter;
				*rx_err     = fdev.tagData.canChipState.rxErrorCounter;
				return 0;
			}
		} else {
			count = 1;
			st = ct_xl_receive(port, &count, &ev);
			if (st == 0 && count > 0 && ev.tag == CT_XL_CHIP_STATE) {
				*bus_status = ev.tagData.raw[0];
				*tx_err     = ev.tagData.raw[1];
				*rx_err     = ev.tagData.raw[2];
				return 0;
			}
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
	if (!ct_vec_xproc) {
		/* GLOBAL, so a console session and an RDP session see ONE object. `Local\` is per
		 * session: two operators on one machine each took their own lock, protected nothing
		 * from each other, and interleaved snapshots and restores of the same persistent
		 * assignments. Falling back to Local\ when the global namespace is refused — some
		 * accounts lack SeCreateGlobalPrivilege — because one session's protection is better
		 * than none. */
		ct_vec_xproc = CreateMutexA(NULL, FALSE, "Global\\blobly_net_vector_borrow");
		if (!ct_vec_xproc) ct_vec_xproc = CreateMutexA(NULL, FALSE, "Local\\blobly_net_vector_borrow");
	}
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
/* 0 not assigned, 1 assigned and the hardware is here, 2 assigned to hardware that is NOT.
 *
 * Reducing the last two to "absent" made --list report that nothing was assigned and send the
 * operator off to rewrite a mapping that was perfectly correct — the adapter was merely
 * unplugged. The assignment is a fact about the configuration; the mask is a fact about the
 * moment. */
static int ct_vector_present(unsigned int app_channel) {
	int why = 0;
	if (ct_vector_mask_why(app_channel, &why, 0) != 0) return 1;
	return (why == -1001) ? 2 : 0;
}

#endif /* CT_VECTOR_SHIM_H */
