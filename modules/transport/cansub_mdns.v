module transport

import net
import time

// A CANsub is found by mDNS, never by a driver: it enumerates as a USB network adapter and
// registers `_cansub._tcp.local`, instance `<id>-usb`, with a TXT record naming its API version
// and channel count (measured on a CANsub.4, 2026-08-28, #235). `cansub_resolves` asks the OS
// resolver about a KNOWN id; this file is the reverse -- a PTR browse that finds every attached
// device, so the Discover dialog can list them instead of sending the operator to type an id.
//
// RAW mDNS, on purpose. The OS resolver can resolve a name but not browse a service type, and
// the browse APIs differ per platform (avahi, Bonjour, DnsServiceBrowse) where a multicast
// query is one UDP exchange that works on both. Two things the bench taught: the device answers
// MULTICAST, not unicast-to-the-querier (a QU query got nothing), so the socket has to share
// port 5353 with whatever mDNS responder the host runs and be joined to the group; and the
// query has to go out of EVERY interface, because the device sits on its own USB subnet and a
// default-route send never reaches it.
//
// NOT part of list_interfaces(). A browse waits its whole window, so it is asked for by the
// one caller that wants it -- the Discover dialog, off its render thread -- and not paid by
// every bench tool that lists vendor channels (self-review).
const cansub_mdns_group = '224.0.0.251'
const cansub_mdns_port = 5353
const cansub_mdns_service = '_cansub._tcp.local'

// cansub_mdns_window is how long a browse listens. A device answers within a few ms; the rest is
// margin for a busy host, and it is paid in full, so it is short.
pub const cansub_mdns_window = 700 * time.millisecond

// CansubService is one attached device as mDNS describes it.
pub struct CansubService {
pub mut:
	id       string // `e5a16adf` -- the address a `cansub:` iface is made from
	host     string // `e5a16adf-usb.local`
	addr     string // the A record, informational: the name is the identity, the address moves
	port     int
	api      string // TXT api=, e.g. `04.00`
	channels int    // TXT channels=, e.g. 4; 0 when the TXT has not been seen
}

// cansub_mdns_query is the one PTR question, QM (multicast response), id 0 as mDNS asks.
pub fn cansub_mdns_query() []u8 {
	mut q := []u8{}
	q << [u8(0), 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
	for label in cansub_mdns_service.split('.') {
		q << u8(label.len)
		q << label.bytes()
	}
	q << 0
	q << [u8(0), 12, 0, 1] // PTR, IN
	return q
}

// cansub_instance_id is the device id in an mDNS instance name -- `e5a16adf-usb` (with or
// without the service suffix) -> `e5a16adf` -- or none for an instance this backend could not
// open: one without the `-usb` the device registers (a renamed instance, `e5a16adf-usb (2)`,
// or another product), or an id parse_cansub_iface would refuse. Lower-cased, as the parser
// lower-cases an id, so a discovered row and a typed one compare equal.
pub fn cansub_instance_id(instance string) ?string {
	mut label := instance.to_lower()
	suffix := '.' + cansub_mdns_service
	if label.ends_with(suffix) {
		label = label[..label.len - suffix.len]
	}
	if !label.ends_with(cansub_host_suffix) {
		return none
	}
	id := label[..label.len - cansub_host_suffix.len]
	if !cansub_id_ok(id) {
		return none
	}
	return id
}

// The record kinds a browse reads, by their DNS type numbers, so the decode and the
// interpretation name one thing.
enum MdnsType {
	a   = 1
	ptr = 12
	txt = 16
	srv = 33
}

// One resource record with its names already resolved, so nothing downstream touches offsets.
struct MdnsRecord {
mut:
	name   string // owner, lower-cased
	rtype  int
	target string // PTR/SRV target, lower-cased
	port   int    // SRV
	txt    []string
	addr   string // A
}

// mdns_name reads a possibly-compressed name at `off`; returns the name and the offset after
// it (after the pointer, when it ended in one).
fn mdns_name(data []u8, off int) !(string, int) {
	mut labels := []string{}
	mut i := off
	mut end := -1
	mut hops := 0
	for {
		if i >= data.len {
			return error('mdns: name runs past the packet')
		}
		l := int(data[i])
		if l == 0 {
			i++
			break
		}
		if l & 0xC0 == 0xC0 {
			if i + 1 >= data.len {
				return error('mdns: truncated pointer')
			}
			if end < 0 {
				end = i + 2
			}
			i = ((l & 0x3F) << 8) | int(data[i + 1])
			hops++
			if hops > 32 {
				return error('mdns: pointer loop')
			}
			continue
		}
		if i + 1 + l > data.len {
			return error('mdns: label runs past the packet')
		}
		labels << data[i + 1..i + 1 + l].bytestr()
		i += 1 + l
	}
	return labels.join('.').to_lower(), if end < 0 {
		i
	} else {
		end
	}
}

// mdns_records decodes a response into its records. The FRAMING is strict -- a record whose
// header or rdata runs past the packet ends the decode, because every offset after it is a
// guess -- but the CONTENT of one record is tolerated: an mDNS responder bundles every service
// it knows into one packet, so a name pointer it got wrong in some printer's SRV must skip that
// record and not discard the CANsub answer beside it (self-review).
fn mdns_records(data []u8) ![]MdnsRecord {
	if data.len < 12 {
		return error('mdns: short packet')
	}
	if data[2] & 0x80 == 0 {
		return error('mdns: not a response')
	}
	qd := (int(data[4]) << 8) | int(data[5])
	total := ((int(data[6]) << 8) | int(data[7])) + ((int(data[8]) << 8) | int(data[9])) +
		((int(data[10]) << 8) | int(data[11]))
	mut off := 12
	for _ in 0 .. qd {
		_, next := mdns_name(data, off)!
		off = next + 4
		if off > data.len {
			return error('mdns: truncated question')
		}
	}
	mut out := []MdnsRecord{}
	for _ in 0 .. total {
		name, next := mdns_name(data, off)!
		off = next
		if off + 10 > data.len {
			return error('mdns: truncated record')
		}
		rtype := (int(data[off]) << 8) | int(data[off + 1])
		rdlen := (int(data[off + 8]) << 8) | int(data[off + 9])
		off += 10
		if off + rdlen > data.len {
			return error('mdns: truncated rdata')
		}
		rdata_end := off + rdlen
		mut r := MdnsRecord{
			name:  name
			rtype: rtype
		}
		mut keep := true
		match rtype {
			int(MdnsType.ptr) {
				if rdlen == 0 {
					keep = false
				} else {
					r.target, _ = mdns_name(data, off) or {
						keep = false
						'', 0
					}
				}
			}
			int(MdnsType.srv) {
				if rdlen < 7 {
					keep = false
				} else {
					r.port = (int(data[off + 4]) << 8) | int(data[off + 5])
					r.target, _ = mdns_name(data, off + 6) or {
						keep = false
						'', 0
					}
				}
			}
			int(MdnsType.txt) {
				mut i := off
				for i < rdata_end {
					l := int(data[i])
					if i + 1 + l > rdata_end {
						break
					}
					r.txt << data[i + 1..i + 1 + l].bytestr()
					i += 1 + l
				}
			}
			int(MdnsType.a) {
				if rdlen == 4 {
					r.addr = '${data[off]}.${data[off + 1]}.${data[off + 2]}.${data[off + 3]}'
				}
			}
			else {}
		}

		if keep {
			out << r
		}
		off = rdata_end
	}
	return out
}

// cansub_mdns_parse turns one response into the devices it describes: PTR names the instance,
// SRV the host and port, TXT the api and channel count, A the address. Every name is compared
// lower-cased, because DNS names are case-insensitive and a responder may spell one record's
// owner differently from another's. A response missing pieces still yields the device with what
// it had; the caller merges packets (see cansub_merge).
pub fn cansub_mdns_parse(data []u8) ![]CansubService {
	recs := mdns_records(data)!
	// Keyed by instance; a V map keeps insertion order, which is the packet's order.
	mut by_instance := map[string]CansubService{}
	for r in recs {
		if r.rtype == int(MdnsType.ptr) && r.name == cansub_mdns_service {
			if id := cansub_instance_id(r.target) {
				if r.target !in by_instance {
					by_instance[r.target] = CansubService{
						id:   id
						host: cansub_host(id)
					}
				}
			}
		}
	}
	for r in recs {
		if r.name !in by_instance {
			continue
		}
		mut d := by_instance[r.name]
		match r.rtype {
			int(MdnsType.srv) {
				d.host = r.target
				d.port = r.port
			}
			int(MdnsType.txt) {
				for kv in r.txt {
					if kv.starts_with('api=') {
						d.api = kv.all_after('api=')
					} else if kv.starts_with('channels=') {
						d.channels = kv.all_after('channels=').int()
					}
				}
			}
			else {}
		}

		by_instance[r.name] = d
	}
	for r in recs {
		if r.rtype != int(MdnsType.a) {
			continue
		}
		for inst, d in by_instance {
			if d.host == r.name {
				by_instance[inst] = CansubService{
					...d
					addr: r.addr
				}
			}
		}
	}
	return by_instance.values()
}

// cansub_merge folds a device seen again into the one already found: a responder may put the
// SRV/TXT/A in a second message, or answer each interface's query separately, so a later packet
// fills what an earlier one lacked and never replaces what it had.
pub fn cansub_merge(mut found []CansubService, d CansubService) {
	for mut f in found {
		if f.id != d.id {
			continue
		}
		if f.port == 0 {
			f.port = d.port
			f.host = d.host
		}
		if f.addr == '' {
			f.addr = d.addr
		}
		if f.api == '' {
			f.api = d.api
		}
		if f.channels == 0 {
			f.channels = d.channels
		}
		return
	}
	found << d
}

// has_label_ci reports whether the DNS label `label` (ASCII, lower-case) occurs in the packet
// in any case -- a cheap pre-filter, no allocation: mDNS compression only points within a
// packet, so a response about the service spells the label once, in whatever case the
// responder used.
fn has_label_ci(pkt []u8, label string) bool {
	if pkt.len < label.len {
		return false
	}
	for i in 0 .. pkt.len - label.len + 1 {
		mut ok := true
		for j in 0 .. label.len {
			mut c := pkt[i + j]
			if c >= `A` && c <= `Z` {
				c += 32
			}
			if c != label[j] {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// CansubBrowse is what a browse came back with: the devices, and a note when it could ask only
// some of the interfaces -- which is not a failure, and not silence either.
pub struct CansubBrowse {
pub:
	devices []CansubService
	note    string
}

// cansub_browse asks every interface for `_cansub._tcp` and collects what answers within the
// window. No devices is the ordinary answer -- nothing attached -- and is not an error; what IS
// an error is not having been able to ask: port 5353 refused, no interface enumerated, no join
// accepted. Those must reach the operator, or "no device" and "could not look" are one blank
// list (the silent-negative Discover has been caught on before, #192). A join that some
// interfaces refused is reported in the note, because the device may be behind exactly one of
// them.
pub fn cansub_browse(window time.Duration) !CansubBrowse {
	mut conn := net.listen_udp('0.0.0.0:${cansub_mdns_port}') or {
		return error('mDNS port ${cansub_mdns_port} could not be shared: ${err.msg()}')
	}
	defer {
		conn.close() or {}
	}
	addrs := local_ipv4_addrs()
	if addrs.len == 0 {
		return error('no IPv4 interface could be enumerated (is `ip` / `ipconfig` available?)')
	}
	mut joined := []string{}
	mut refused := []string{}
	for a in addrs {
		conn.join_multicast_group(cansub_mdns_group, a) or {
			refused << a
			continue
		}
		joined << a
	}
	if joined.len == 0 {
		return error('no interface would join the mDNS group ${cansub_mdns_group} (tried ${addrs.join(', ')})')
	}
	group := cansub_mdns_group.split('.').map(u8(it.int()))
	dst := net.new_ip(u16(cansub_mdns_port), [group[0], group[1], group[2], group[3]]!)
	q := cansub_mdns_query()
	for a in joined {
		conn.set_multicast_interface(a) or { continue }
		conn.write_to(dst, q) or {}
	}
	// Each read waits for what is LEFT of the window, so the wall clock is the window and not
	// the window plus a timeout. V's read deadline is not honoured for UDP
	// (docs/known_issues.md), which is why the timeout is re-armed per read. Only the timeout
	// ends the browse: an empty datagram comes back from V as an error too, and a browse ended by
	// one would be "nothing attached" with nothing to say why. Any other error is waited out
	// rather than spun on -- the window bounds it.
	deadline := time.ticks() + window.milliseconds()
	mut buf := []u8{len: 9000}
	mut found := []CansubService{}
	for {
		remaining := deadline - time.ticks()
		if remaining <= 0 {
			break
		}
		conn.set_read_timeout(remaining * time.millisecond)
		n, _ := conn.read(mut buf) or {
			if err.code() == net.err_timed_out_code {
				break
			}
			time.sleep(time.millisecond)
			continue
		}
		if n <= 0 {
			time.sleep(time.millisecond)
			continue
		}
		pkt := buf[..n]
		// Every mDNS packet on every segment lands here for the whole window; only one that
		// carries the service label is worth parsing.
		if !has_label_ci(pkt, '_cansub') {
			continue
		}
		devices := cansub_mdns_parse(pkt) or { continue }
		for d in devices {
			cansub_merge(mut found, d)
		}
	}
	note := if refused.len > 0 {
		'asked ${joined.len} of ${addrs.len} interfaces; not joined: ${refused.join(', ')}'
	} else {
		''
	}
	return CansubBrowse{
		devices: found
		note:    note
	}
}

// cansub_rows is the Discover dialog's view of what a browse found: one row per channel, named
// for the operator and addressed for open(). Channel count is the device's word, clamped to what
// parse_cansub_iface will accept -- a row the address parser refuses must not be offered -- and a
// device whose TXT never arrived is shown with its first channel, which every CANsub has. The
// rate is left to the row: a device does not know what bus it will be put on.
pub fn cansub_rows(devices []CansubService) []Iface {
	mut out := []Iface{}
	for d in devices {
		mut n := d.channels
		if n < 1 {
			n = 1
		}
		if n > cansub_channels {
			n = cansub_channels
		}
		note := if d.api != '' { ' (api ${d.api})' } else { '' }
		for ch in 1 .. n + 1 {
			out << Iface{
				name:  'CANsub ${d.id} channel ${ch}${note}'
				iface: 'cansub:${d.id}/${ch}'
				kind:  'cansub'
			}
		}
	}
	return out
}

// discover_cansub is what the Discover dialog calls, off its render thread: a browse of the
// default window, as rows, with the browse's note. An error is the browse not having been
// possible, never "nothing attached".
pub fn discover_cansub() !([]Iface, string) {
	b := cansub_browse(cansub_mdns_window)!
	return cansub_rows(b.devices), b.note
}
