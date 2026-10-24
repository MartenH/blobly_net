module script

import blobly.isotp
import blobly.uds

@[heap]
struct Said {
mut:
	lines []string
}

// A DoIP connection reopened in its slot (open_uds) keeps what the keep-alive of the one it
// replaces had not said: the next call on the slot says it.
fn test_a_reopened_connection_says_the_keep_alive_failure_of_the_one_it_replaced() {
	mut env := new_env([]ChanInfo{})!
	defer {
		env.close()
	}
	mut said := &Said{}
	env.on_output = fn [mut said] (s string) {
		said.lines << s
	}
	mut old := new_conn(UdsConn{
		ch:   isotp.UnopenedChannel{}
		cli:  uds.Client{}.on_heap()
		chan: 'DoIP1'
	})
	old.ka_said = 'keep-alive 3E 80 refused (NRC 0x11)'
	env.conns << old
	env.conns[0] = env.conns[0].succeeded_by(new_conn(UdsConn{
		ch:   isotp.UnopenedChannel{}
		cli:  uds.Client{}.on_heap()
		chan: 'DoIP1'
	}))
	env.conn(0) or { panic('no connection 0') }
	assert said.lines == ['DoIP1: keep-alive 3E 80 refused (NRC 0x11)']
	env.conn(0) or { panic('no connection 0') }
	assert said.lines.len == 1 // said once
}
