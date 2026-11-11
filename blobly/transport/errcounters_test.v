module transport

// A kernel error frame with CAN_ERR_CNT carries TEC in data[6] and REC in data[7]; without the
// flag the bytes are not counters (linux/can/error.h).
fn test_socketcan_err_counters() {
	cnt := [u8(0), 0x08, 0, 0, 0, 0, 100, 7]
	c := socketcan_err_counters(0x2000_0204, cnt) or { panic('CAN_ERR_CNT not read') }
	assert c.known && c.tx == 100 && c.rx == 7
	assert c.str() == 'TEC 100 REC 7'
	assert socketcan_err_counters(0x2000_0004, cnt) == none
	assert socketcan_err_counters(0x2000_0200, [u8(0), 0, 0]) == none
	assert socketcan_err_counters(0x2000_0200, []u8{len: 8, init: 0xff})?.tx == 255
}

// The shim packs busStatus, TEC and REC into one int; -1 is "no chip-state event yet" and a zero
// busStatus is a driver that has not said.
fn test_vector_chip_word() {
	w := vector_chip_word(0x02, 130, 4)
	assert vector_chip_status(w) == 0x02
	assert xl_chipstat_health(u8(vector_chip_status(w))) == .error_passive
	c := vector_chip_counters(w)
	assert c.known && c.tx == 130 && c.rx == 4
	assert vector_chip_word(0x01, 255, 255) > 0
	assert vector_chip_counters(vector_chip_word(0x01, 255, 255)).tx == 255
	assert vector_chip_status(-1) == -1
	assert !vector_chip_counters(-1).known
	assert !vector_chip_counters(vector_chip_word(0, 9, 9)).known
	assert ErrorCounters{}.str() == ''
}

// The CANsub status body as the device answers it, a monitor at the firmware's start value.
fn test_cansub_counters() {
	c := cansub_counters('{"state":"error_passive","tx_error_count":129,"rx_error_count":0,"frame_count":0}') or {
		panic('counters not read')
	}
	assert c.known && c.tx == 129 && c.rx == 0
	spaced := cansub_counters('{ "rx_error_count" : 12 , "tx_error_count" : 3 }')?
	assert spaced.tx == 3 && spaced.rx == 12
	assert cansub_counters('{"state":"error_active","rx_error_count":0}') == none
}

// The software buses have no controller.
fn test_software_buses_cannot_say() {
	mut b := open('inproc:errcounters_test') or { panic(err) }
	defer {
		b.close()
	}
	assert !b.error_counters().known
}

// CountingBus is a bus whose controller reports counters, for the wrappers to pass through.
struct CountingBus {
mut:
	closed bool
}

fn (mut c CountingBus) send(_ CanFrame) ! {}

fn (mut c CountingBus) recv(_ int) !CanFrame {
	return error('timeout')
}

fn (mut c CountingBus) reconcile_silence(_ bool) ! {}

fn (mut c CountingBus) close() {
	c.closed = true
}

fn (mut c CountingBus) health() BusHealth {
	return .warning
}

fn (mut c CountingBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{}
}

fn (mut c CountingBus) error_counters() ErrorCounters {
	return ErrorCounters{
		tx:    97
		rx:    3
		known: true
	}
}

fn counting_make(_ string) !Bus {
	return &CountingBus{}
}

fn assert_counted(mut b Bus, what string) {
	c := b.error_counters()
	assert c.known && c.tx == 97 && c.rx == 3, '${what} dropped the counters: ${c}'
}

// Every wrapper a handle is made of passes its inner bus's counters through: open()'s SilentBus,
// a row's emitter, a script's MeteredBus, a Vector port's pin and a shared-hub handle.
fn test_wrappers_pass_counters_through() {
	mut silent := silenced('errcnt:silent', &CountingBus{})
	assert_counted(mut silent, 'SilentBus')
	mut row := row_framed(silent, 'errcnt:silent', 'Row')
	assert_counted(mut row, 'RowFramedBus')
	mut meter := Bus(metered(row, 'errcnt:silent', 500000, 0))
	assert_counted(mut meter, 'MeteredBus')
	mut pin := pinned_open('vector:11@500000', counting_make)!
	assert_counted(mut pin, 'PinnedBus')
	pin.close()
	mut hub := shared_open('errcnt:hub', 'errcnt:hub', counting_make)!
	assert_counted(mut hub, 'SharedHandle')
	hub.close()
	assert !hub.error_counters().known
}
