module script

import lua
import blobly.uds

// diag:authenticate(level [, {key = ...}]) — 0x29 Authentication (ACR with Ed25519) on an ECU that
// unlocks that way (blobly_emb `[uds] access = "authentication"`): uds.Client.authenticate on the
// connection. The key is the tester's Ed25519 SEED: absent or "reference" the dev tester key (the one
// such a node's auth_keys "reference" trusts), 64 hex characters, or a seed file's path, resolved
// against the script's directory like `-- @project`. A key that is given and is not a non-empty
// string (false, a number, a table) is refused before anything is sent.

// __uds_authenticate(handle, level, key|nil)
fn l_uds_authenticate(l lua.State) i32 {
	mut env := env_of(l)
	mut c, _ := env.conn_arg(l, 1) or { return l.fail('diag:authenticate: ${err}') }
	level := int_arg(l, 2, 'the security level', 1, 8) or {
		return l.fail('diag:authenticate: ${err}')
	}
	// a key option that is given is a string naming a key: false, a number or a table is refused
	// by name, never read as the empty string the dev key once was (uds.tester_key refuses '' too)
	if !l.arg_absent(3) && !l.arg_is_string(3) {
		return l.fail('diag:authenticate: key must be a string ("reference", 64 hex characters or a seed file), got ${l.arg_given(3)}')
	}
	spec := if l.arg_absent(3) { 'reference' } else { l.arg_str(3) }
	if spec.trim_space() == '' {
		return l.fail('diag:authenticate: key is empty — leave it out, or write "reference", for the dev tester key')
	}
	resolved := if uds.names_key_text(spec) { spec } else { env.script_relative(spec) }
	seed := uds.tester_key(resolved) or { return l.fail('diag:authenticate: key: ${err}') }
	c.cli.authenticate(int(level), seed) or { return l.fail(err.msg()) }
	return 0
}
