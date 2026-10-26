module headless

import os
import time
import blobly.transport

// Two enabled rows dispute one wire — a canfd row and a can row — so the wire is undeclared, and
// each row's own emitters send in its own row's format (#384).
const disputed_project = 'project:
  name: disputed wire
  version: 8
channels:
  - name: FD
    type: canfd
    interface: inproc:HDISPUTE
    bitrate: 500000
    data_bitrate: 2000000
    databases:
      - DBC
    simulation:
      - name: SUT
    senders:
      - name: FdRaw
        id: "0x321"
        data: 01 02
        trigger: cyclic
        cycle_ms: 20
  - name: CL
    type: can
    interface: inproc:HDISPUTE
    bitrate: 500000
    databases:
      - DBC
    simulation:
      - name: BodyECU
    senders:
      - name: ClRaw
        id: "0x322"
        data: 03 04
        trigger: cyclic
        cycle_ms: 20
'

fn test_each_row_emitter_on_a_disputed_wire_sends_its_own_format() {
	dir := os.join_path(os.vtmp_dir(), 'headless_disputed_${os.getpid()}')
	os.mkdir_all(dir)!
	path := os.join_path(dir, 'disputed.blobnet')
	os.write_file(path, disputed_project.replace('DBC', os.join_path(@VMODROOT, 'dbc',
		'blobly_net.dbc')))!
	proj := load(path, Options{})!
	mut r := start(proj, path, Options{})!
	mut bus := transport.open('inproc:HDISPUTE')!
	defer {
		bus.close()
		r.stop()
	}
	assert !transport.wire_framing('inproc:HDISPUTE').fd, 'the rows disagree, so the wire is undeclared'
	want := {
		u32(0x321): true // the FD row's generator
		0x100:      true // its simulated SUT (Powertrain)
		0x7E8:      true // its diagnostic server answering
		0x322:      false // the classic row's generator
		0x200:      false // its simulated BodyECU (BodyStatus)
	}
	mut seen := map[u32]bool{}
	until := time.ticks() + 3000
	mut asked := i64(0)
	for time.ticks() < until && seen.len < want.len {
		// a tester request to the wire's default diagnostic server, the FD row's (3E 00), again
		// until answered: the server's loop subscribes on a thread of its own
		if u32(0x7E8) !in seen && time.ticks() - asked >= 200 {
			asked = time.ticks()
			bus.send(transport.CanFrame{ id: 0x7E0, data: [u8(0x02), 0x3E, 0x00, 0, 0, 0, 0, 0] })!
		}
		f := bus.recv(20) or { continue }
		if fd := want[f.id] {
			assert f.fd == fd, '0x${f.id:X} went out ${if f.fd { 'FD' } else { 'classic' }}'
			if fd {
				assert f.brs, '0x${f.id:X}: the FD row switches its data rate'
			}
			seen[f.id] = true
		}
	}
	assert seen.len == want.len, 'heard ${seen.keys().map('0x${it:X}')}'
}
