module script

import blobly.candb

// a DBC with what the catalog describes: units, ranges, value labels, a signed and a big-endian
// signal, a multiplexed message, and an extended id
fn catalog_db() candb.Database {
	return candb.Database{
		messages: [
			candb.Message{
				name:     'Powertrain'
				id:       0x100
				dlc:      8
				cycle_ms: 100
				signals:  [
					candb.Signal{
						name:      'EngineSpeed'
						start_bit: 0
						length:    16
						factor:    0.25
						maximum:   16383.75
						unit:      'rpm'
					},
					candb.Signal{
						name:      'Gear'
						start_bit: 16
						length:    4
						maximum:   15
						values:    {
							u64(0): 'Neutral'
							3:      'Third'
						}
					},
					candb.Signal{
						name:      'Temp'
						start_bit: 24
						length:    8
						is_signed: true
						factor:    0.5
						offset:    10
						minimum:   -54
						maximum:   73.5
						unit:      'degC'
						values:    {
							u64(0xFF): 'Fault'
						}
						start_raw: 0xFE
						has_start: true
					},
					candb.Signal{
						name:       'Pressure'
						start_bit:  39
						length:     16
						byte_order: .big_endian
					},
				]
			},
			candb.Message{
				name:           'Muxed'
				id:             0x18FF0001
				ext:            true
				dlc:            2
				send_type_name: 'spontaneous'
				send_type:      .event
				repetitions:    2
				delay_ms:       20
				signals:        [
					candb.Signal{
						name:           'Page'
						start_bit:      0
						length:         8
						is_multiplexor: true
					},
					candb.Signal{
						name:              'PageOne'
						start_bit:         8
						length:            8
						is_multiplexed:    true
						multiplexor_value: 1
					},
				]
			},
		]
	}
}

fn catalog_env() &Env {
	mut env := new_env([ChanInfo{
		name:  'CAN1'
		iface: 'inproc:UTCAT'
		db:    catalog_db()
	}]) or { panic(err) }
	env.on_output = fn (s string) {}
	return env
}

fn test_the_catalog_lists_messages_and_describes_signals() {
	mut env := catalog_env()
	defer { env.close() }
	env.run_source('
		test("messages in database order", function()
			local ms = dbc.messages("CAN1")
			check.equal(#ms, 2)
			check.equal(ms[1].name, "Powertrain")
			check.equal(ms[1].id, 0x100)
			check.equal(ms[1].ext, false)
			check.equal(ms[1].dlc, 8)
			check.equal(#ms[1].signals, 4)
			check.equal(ms[2].name, "Muxed")
			check.equal(ms[2].ext, true)
		end)
		test("a message by name and by id", function()
			check.equal(dbc.message("CAN1", "Muxed").id, 0x18FF0001)
			check.equal(dbc.message("CAN1", 0x18FF0001, true).name, "Muxed")
			check.equal(dbc.message("CAN1", 0x18FF0001), nil)
			check.equal(dbc.message("CAN1", "Nope"), nil)
			check.equal(dbc.message("CAN1", 0x7FF), nil)
			check.equal(dbc.message("CAN1", 0x18FF0002, true), nil)
			check.equal(decode("CAN1", 0x18FF0002, string.char(1, 7), true).PageOne, 7)
			check.equal(pcall(dbc.message, "CAN1", 0x100000100), false)
			check.equal(pcall(dbc.message, "CAN1", -1), false)
			check.equal(pcall(dbc.message, "CAN1", 256.5), false)
		end)
		test("a signal metadata", function()
			local s = dbc.signal("CAN1", "Powertrain", "EngineSpeed")
			check.equal(s.unit, "rpm")
			check.equal(s.factor, 0.25)
			check.equal(s.maximum, 16383.75)
			check.equal(s.byte_order, "little")
			check.equal(s.signed, false)
			check.equal(s.start_bit, 0)
			check.equal(s.length, 16)
			check.equal(s.multiplexed, false)
			check.equal(s.mux_value, nil)
			local t = dbc.signal("CAN1", 0x100, "Temp")
			check.equal(t.signed, true)
			check.equal(t.offset, 10)
			check.equal(t.minimum, -54)
			check.equal(dbc.signal("CAN1", "Powertrain", "Pressure").byte_order, "big")
			check.equal(dbc.signal("CAN1", "Powertrain", "Nope"), nil)
			check.equal(dbc.signal("CAN1", 0x18FF0001, "Page", true).multiplexor, true)
			check.equal(dbc.signal("CAN1", 0x18FF0001, "Page"), nil)
		end)
		test("value labels by physical value and by raw key", function()
			local g = dbc.signal("CAN1", "Powertrain", "Gear")
			check.equal(g.labels[3], "Third")
			check.equal(g.raw_labels[0], "Neutral")
			local t = dbc.signal("CAN1", "Powertrain", "Temp")
			check.equal(t.raw_labels[0xFF], "Fault")
			check.equal(t.labels[9.5], "Fault")
		end)
		test("mux roles", function()
			local p = dbc.signal("CAN1", "Muxed", "Page")
			check.equal(p.multiplexor, true)
			local one = dbc.signal("CAN1", "Muxed", "PageOne")
			check.equal(one.multiplexed, true)
			check.equal(one.mux_value, 1)
		end)
		test("send attributes and start values", function()
			local p = dbc.message("CAN1", "Powertrain")
			check.equal(p.cycle_ms, 100)
			check.equal(p.send_type, nil)
			local m = dbc.message("CAN1", "Muxed")
			check.equal(m.send_type, "event")
			check.equal(m.repetitions, 2)
			check.equal(m.delay_ms, 20)
			check.equal(m.cycle_ms, 0)
			local t = dbc.signal("CAN1", "Powertrain", "Temp")
			check.equal(t.start_raw, 0xFE)
			check.equal(t.start, 9)
			check.equal(dbc.signal("CAN1", "Powertrain", "Gear").start, nil)
		end)
	')!
	assert env.total() == 6
	assert env.passed() == 6, '${env.results}'
}

fn test_decode_reports_raw_values_and_labels_for_what_a_frame_carries() {
	mut env := catalog_env()
	defer { env.close() }
	env.run_source('
		local f = string.char(0x40, 0x06, 0x03, 0xFF, 0, 0, 0, 0)
		test("physical by default", function()
			local d = decode("CAN1", 0x100, f)
			check.equal(d.EngineSpeed, 400)
			check.equal(d.Temp, 9.5)
			check.equal(decode("CAN1", 0x100, f, false, "physical").Temp, 9.5)
		end)
		test("raw is the field bits", function()
			local r = decode("CAN1", 0x100, f, false, "raw")
			check.equal(r.EngineSpeed, 0x0640)
			check.equal(math.type(r.EngineSpeed), "integer")
			check.equal(r.Gear, 3)
			check.equal(r.Temp, 0xFF)
		end)
		test("label is the value table text, and only where there is one", function()
			local l = decode("CAN1", 0x100, f, false, "label")
			check.equal(l.Gear, "Third")
			check.equal(l.Temp, "Fault")
			check.equal(l.EngineSpeed, nil)
			check.equal(decode("CAN1", 0x100, string.char(0, 0, 5), false, "label").Gear, nil)
		end)
		test("a short payload carries no signal it does not hold", function()
			local r = decode("CAN1", 0x100, string.char(0x40, 0x06, 0x03), false, "raw")
			check.equal(r.Gear, 3)
			check.equal(r.Temp, nil)
			check.equal(decode("CAN1", 0x100, string.char(0x40), false, "raw").EngineSpeed, nil)
			check.equal(decode("CAN1", 0x100, string.char(0x40, 0x06, 0x03), false, "label").Temp, nil)
		end)
		test("an unselected mux branch is not carried", function()
			check.equal(decode("CAN1", 0x18FF0001, string.char(2, 7), true, "raw").PageOne, nil)
			check.equal(decode("CAN1", 0x18FF0001, string.char(1, 7), true, "raw").PageOne, 7)
		end)
		test("an unknown mode is refused", function()
			check.equal(pcall(function() decode("CAN1", 0x100, f, false, "labels") end), false)
			check.equal(pcall(function() decode("CAN1", 0x100, f, false, "") end), false)
			check.equal(pcall(function() decode("CAN1", 0x100, f, false, { labels = true }) end), false)
		end)
	')!
	assert env.total() == 6
	assert env.passed() == 6, '${env.results}'
}

// a signal wider than 64 bits carries no number: decode leaves it out and send_message refuses it
fn test_a_wide_signal_is_left_out_of_decode_and_refused_by_send_message() {
	mut env := new_env([ChanInfo{
		name:  'CAN1'
		iface: 'inproc:UTWIDE'
		db:    candb.parse_dbc('BO_ 1280 ConfigData: 24 A\n SG_ Mode : 0|8@1+ (1,0) [0|255] "" A\n SG_ Key : 8|128@1+ (1,0) [0|0] "" A\n') or {
			panic(err)
		}
	}]) or { panic(err) }
	env.on_output = fn (s string) {}
	defer { env.close() }
	env.run_source('
		test("decode leaves it out", function()
			local d = decode("CAN1", 0x500, string.rep(string.char(1), 24), false, "raw")
			check.equal(d.Mode, 1)
			check.equal(d.Key, nil)
		end)
		test("send_message refuses it", function()
			local ok, why = pcall(function() bus.send_message("CAN1", "ConfigData", { Key = 1 }) end)
			check.equal(ok, false)
			check.truthy(tostring(why):find("Key is 128 bits wide: a value is encoded into 1 .. 64", 1, true))
		end)
	')!
	assert env.total() == 2
	assert env.passed() == 2, '${env.results}'
}
