module project

// RowKind is what a row of `buses:` is, the one answer every site that treats a row by its kind
// asks: a CAN bus (CAN or CAN-FD, on any adapter), a DoIP endpoint, or a SOME/IP listener. A site
// that treats each kind its own way matches on it exhaustively, so a kind added here is a compile
// error at every site that has to decide what to do with it; a site asking "is this a CAN wire?"
// compares with `.can`, so a new kind is not mistaken for one.
pub enum RowKind {
	can
	doip
	someip
}

// name is the kind as the Log and the refusals name it.
pub fn (k RowKind) name() string {
	return match k {
		.can { 'CAN' }
		.doip { 'DoIP' }
		.someip { 'SOME/IP' }
	}
}

// kind is the row's kind: DoIP when its type or its interface's scheme says so (`type: doip`,
// `doip`, `doip:<host>[:<port>]`), else SOME/IP by the same test, else CAN. The parser keeps the
// two in agreement (a type with another scheme's interface is refused).
pub fn (ch Channel) kind() RowKind {
	if ch.typ == 'doip' || iface_scheme_is(ch.iface, 'doip') {
		return .doip
	}
	if ch.typ == 'someip' || iface_scheme_is(ch.iface, 'someip') {
		return .someip
	}
	return .can
}

// kind_of_iface is the kind an interface string names by its scheme alone. Public because the
// runtime asks it of a DESTINATION — a generator names where it sends, not which row it is — and
// that answer must be the rule kind() uses for a row.
pub fn kind_of_iface(iface string) RowKind {
	if iface_scheme_is(iface, 'doip') {
		return .doip
	}
	if iface_scheme_is(iface, 'someip') {
		return .someip
	}
	return .can
}
