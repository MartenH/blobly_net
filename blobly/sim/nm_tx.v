// A simulated node's CanNm PDU: sent on the cluster's cycle while the network is requested, and
// not at all once a script has released it (AUTOSAR CanNm: a node releases by falling silent).
// What a node announces is blobly/nm's rule (nm.announcements); this file sends it.
module sim

import sync
import blobly.candb
import blobly.nm
import blobly.transport

// NmTx is one node's announcement in the engine: its PDU, when it is next due, and whether the
// network is released for it.
pub struct NmTx {
pub mut:
	ann      nm.Announce
	next_ms  f64
	released bool
}

// frame is the announcement as a CAN frame.
pub fn (t NmTx) frame() transport.CanFrame {
	return transport.CanFrame{
		id:       t.ann.id
		extended: t.ann.ext
		data:     t.ann.payload()
	}
}

// attach_announcements gives each ECU of the engine the announcement of its name, due at once.
pub fn (mut e Engine) attach_announcements(anns []nm.Announce) {
	for i := 0; i < e.ecus.len; i++ {
		e.ecus[i].nm_tx = []NmTx{}
		for a in anns {
			if a.node == e.ecus[i].name {
				e.ecus[i].nm_tx << NmTx{
					ann: a
				}
			}
		}
	}
}

// announces: the ECU announces NM on this frame, so the announcement is what goes out on it and
// the database's own cyclic message of that id does not, released or not.
fn (ecu SimEcu) announces(id u32, ext bool) bool {
	for t in ecu.nm_tx {
		if t.ann.id == id && t.ann.ext == ext {
			return true
		}
	}
	return false
}

// announcement_dropped: a drop fault is armed on the ECU's database message of the announced frame,
// which the announcement goes out in place of, so the announcement is what the drop holds back.
fn (ecu SimEcu) announcement_dropped(t NmTx) bool {
	for m in ecu.messages {
		if m.msg.id == t.ann.id && m.msg.ext == t.ann.ext && m.fault.kind == .drop {
			return true
		}
	}
	return false
}

// step_nm sends every announcement due by now_ms. A released one sends nothing and is due again
// the moment the network is requested, as CanNm transmits at once on a request; a dropped one
// keeps its cycle and sends nothing, a frame lost to the fault.
fn (mut e Engine) step_nm(now_ms f64, send fn (f transport.CanFrame) bool) {
	for i := 0; i < e.ecus.len; i++ {
		for j := 0; j < e.ecus[i].nm_tx.len; j++ {
			mut t := &e.ecus[i].nm_tx[j]
			if t.released {
				t.next_ms = now_ms
				continue
			}
			if now_ms + 1e-6 < t.next_ms {
				continue
			}
			if !e.ecus[i].announcement_dropped(*t) {
				send(t.frame())
			}
			t.next_ms += f64(t.ann.cycle_ms)
			if t.next_ms <= now_ms {
				t.next_ms = now_ms + f64(t.ann.cycle_ms)
			}
		}
	}
}

// NmRequests is the process's table of released nodes, by interface, project row and node:
// written by a script, read by every simulation loop, so held behind a mutex. The row is part of
// the key because two rows on one wire may each simulate a node of one name.
pub struct NmRequests {
mut:
	mu       sync.Mutex
	released map[string]bool
}

__global nm_requests = &NmRequests{}

fn nm_key(iface string, row int, node string) string {
	return '${iface}#${row}:${node}'
}

// nm_set_request requests (true) or releases (false) the network for `node` simulated on project
// row `row` on `iface`.
pub fn nm_set_request(iface string, row int, node string, request bool) {
	nm_requests.mu.lock()
	if request {
		nm_requests.released.delete(nm_key(iface, row, node))
	} else {
		nm_requests.released[nm_key(iface, row, node)] = true
	}
	nm_requests.mu.unlock()
}

// nm_requested: the network is requested for `node` on row `row` on `iface` (the default, until
// released).
pub fn nm_requested(iface string, row int, node string) bool {
	nm_requests.mu.lock()
	r := nm_key(iface, row, node) !in nm_requests.released
	nm_requests.mu.unlock()
	return r
}

// clear_nm_requests requests the network for every node again: a run starts with none released.
pub fn clear_nm_requests() {
	nm_requests.mu.lock()
	nm_requests.released = map[string]bool{}
	nm_requests.mu.unlock()
}

// apply_nm_requests stamps the table onto the announcements of the engine simulating project row
// `row` on `iface`.
pub fn apply_nm_requests(iface string, row int, mut e Engine) {
	for i := 0; i < e.ecus.len; i++ {
		for j := 0; j < e.ecus[i].nm_tx.len; j++ {
			e.ecus[i].nm_tx[j].released = !nm_requested(iface, row, e.ecus[i].name)
		}
	}
}

// announced_frame: `msg` is the frame `node` announces NM on, by `anns` (nm.announcements of its
// wire), so the announcement goes out in its place and only a drop reaches the wire.
pub fn announced_frame(anns []nm.Announce, node string, msg candb.Message) bool {
	return anns.any(it.node == node && it.id == msg.id && it.ext == msg.ext)
}

// announced_refusal refuses a fault `kind` other than drop on `msg`, a frame `node` announces NM
// on.
fn (t FaultTarget) announced_refusal(node string, msg candb.Message, kind FaultKind) ! {
	if kind == .drop {
		return
	}
	anns, _ := nm.announcements(t.nm, t.nodes)
	if announced_frame(anns, node, msg) {
		return error('"${msg.name}" is the frame "${node}" announces NM on, sent as its NM PDU — only drop applies to it')
	}
}

// nm_request requests (true) or releases (false) the network for every node simulated on this
// row that announces NM, answering how many; refused where none does, since a release would then
// change nothing on the wire.
pub fn (t FaultTarget) nm_request(request bool) !int {
	if t.not_can != '' {
		return error('"${t.channel}" is a ${t.not_can} channel — nothing simulates NM on it')
	}
	anns, _ := nm.announcements(t.nm, t.nodes)
	if anns.len == 0 {
		return error('no node simulated on ${t.channel} announces NM (a cluster with a cycle, and a node it declares or one with its own nm: entry)')
	}
	mut names := map[string]bool{}
	for a in anns {
		names[a.node] = true
	}
	for name, _ in names {
		nm_set_request(t.iface, t.row, name, request)
	}
	return names.len
}
