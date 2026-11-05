module lin

// Serial LIN is Linux-only: everywhere else a `tty:` or `pty:` address is refused by name.

fn open_serial(a SerialAddr, cfg Config) !Bus {
	return error(serial_unsupported(a.address))
}

pub struct PtyLink {
pub:
	a string
	b string
}

pub fn pty_link() !&PtyLink {
	return error('lin: a pty link is Linux-only in this build')
}

pub fn (l &PtyLink) dropped() u64 {
	return 0
}

pub fn (mut l PtyLink) close() {}
