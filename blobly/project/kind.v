module project

// RowKind is what a row of `buses:` is, the one answer every site that treats a row by its kind
// asks: a CAN bus (CAN or CAN-FD, on any adapter), a DoIP endpoint, a SOME/IP listener, or a LIN
// bus (lin.v). A site that treats each kind its own way matches on it exhaustively, naming every
// kind, so the site that has to decide about a new kind is found (by grep, `match .*kind`, while
// the pinned V3 does not check a plain enum match); a site asking "is this a CAN wire?" compares
// with `.can`, so a new kind is not mistaken for one.
pub enum RowKind {
	can
	doip
	someip
	lin
}

// name is the kind as the Log and the Diagnostics panel name it.
pub fn (k RowKind) name() string {
	return match k {
		.can { 'CAN' }
		.doip { 'DoIP' }
		.someip { 'SOME/IP' }
		.lin { 'LIN' }
	}
}

// has_generators is whether the row's `senders:` run: a CAN row's frames, and a DoIP row's,
// which a generator on its wire may name; a SOME/IP listener transmits nothing, so a row
// converted to one keeps its generators in the file and runs none.
pub fn (k RowKind) has_generators() bool {
	return match k {
		.can, .doip { true }
		.someip, .lin { false }
	}
}

// simulates is whether the row's nodes and `verify:` entries mean anything: simulated ECUs and
// checked frames on a CAN bus, a hosted entity on a DoIP endpoint; nothing on a passive listener,
// and nothing of that kind on a LIN row, whose `simulate:` is LDF nodes its own Row plays.
pub fn (k RowKind) simulates() bool {
	return match k {
		.can, .doip { true }
		.someip, .lin { false }
	}
}

// nodes_have_can_ids is whether a node's diagnostic server is reached by CAN ids (rx, tx,
// functional): not on DoIP, whose node is addressed by the channel's logical pair.
pub fn (k RowKind) nodes_have_can_ids() bool {
	return match k {
		.can, .someip { true }
		.doip, .lin { false }
	}
}

// kind is the row's kind: DoIP when its type or its interface's scheme says so (`type: doip`,
// `doip`, `doip:<host>[:<port>]`), else SOME/IP by the same test, else CAN. The parser keeps the
// two in agreement (a type with another scheme's interface is refused); a row built otherwise
// with both reads as DoIP.
pub fn (ch Channel) kind() RowKind {
	return match ch.typ {
		'lin' { .lin }
		'doip' { .doip }
		'someip' { if kind_of_iface(ch.iface) == .doip { .doip } else { .someip } }
		// a row is LIN by its type, never by an address typed into a CAN row
		else { if ch.adapter == 'lin' { .lin } else { can_or_eth(kind_of_iface(ch.iface)) } }
	}
}

// can_or_eth reads a scheme's kind for a row that is not LIN: a `lin:` interface on one is CAN,
// whose open then fails as the device it is not.
fn can_or_eth(k RowKind) RowKind {
	return if k == .lin { RowKind.can } else { k }
}

// kind_of_iface is the kind an interface string names by its scheme alone. Public because the
// runtime asks it of a DESTINATION — a generator names where it sends, not which row it is — and
// that answer must be the rule kind() uses for a row.
pub fn kind_of_iface(iface string) RowKind {
	if iface_scheme_is(iface, 'lin') {
		return .lin
	}
	if iface_scheme_is(iface, 'doip') {
		return .doip
	}
	if iface_scheme_is(iface, 'someip') {
		return .someip
	}
	return .can
}
