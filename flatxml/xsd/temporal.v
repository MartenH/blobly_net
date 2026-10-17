module xsd

// Comparing dates, times and durations by value (XSD 1.0 Part 2, 3.2.6-3.2.14), for
// enumerations: two literals naming the same value must compare equal however they are written.
// A date or time with a timezone is the instant it names, in UTC; without one it is compared
// with others without one. The g types are the instant they start, on XSD 1.1's reference year
// 1972 where they name no year. A duration is its months and its seconds. A value whose numbers
// are too long to add (a year of more than 15 digits) is compared as written.

// temporal_key is v's value as a key: equal for equal values. '' when v cannot be keyed by value.
fn temporal_key(root Builtin, v string) string {
	return match root {
		.date_time { date_time_key(v) }
		.date { date_key(v) }
		.time { time_key(v) }
		.g_year_month, .g_year, .g_month_day, .g_day, .g_month { g_key(root, v) }
		.duration { duration_key(v) }
		else { '' }
	}
}

// days_from_civil is the day number of a proleptic Gregorian date (1970-01-01 is 0), for any
// astronomical year (1 BCE is 0).
fn days_from_civil(year i64, month int, day int) i64 {
	y := if month <= 2 { year - 1 } else { year }
	era := (if y >= 0 { y } else { y - 399 }) / 400
	yoe := y - era * 400
	mp := if month > 2 { month - 3 } else { month + 9 }
	doy := i64((153 * mp + 2) / 5 + day - 1)
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

// astronomical is a year as XSD 1.0 writes it (no year 0; -0001 is 1 BCE) as an astronomical
// year, or none when it is too long to add.
fn astronomical(y YearInfo) ?i64 {
	if y.digits.len > 15 {
		return none
	}
	n := y.digits.i64()
	return if y.neg { -(n - 1) } else { n }
}

// tz_minutes reads a timezone ('', Z or (+|-)hh:mm) as minutes east of UTC; none for none.
fn tz_minutes(s string) ?int {
	if s == '' {
		return none
	}
	if s == 'Z' {
		return 0
	}
	m := int(s[1] - `0`) * 600 + int(s[2] - `0`) * 60 + int(s[4] - `0`) * 10 + int(s[5] - `0`)
	return if s[0] == `-` { -m } else { m }
}

// instant_key is the key of a moment: seconds from 1970 in UTC (with its fraction) when it has a
// timezone, as local seconds marked with no timezone otherwise.
fn instant_key(year i64, month int, day int, secs i64, frac string, tz ?int) string {
	mut s := days_from_civil(year, month, day) * 86400 + secs
	mark := if t := tz {
		s -= i64(t) * 60
		'Z'
	} else {
		'L'
	}
	return if frac == '' { '${s}${mark}' } else { '${s}.${frac}${mark}' }
}

// clock_parts reads hh:mm:ss(.f)? as seconds and the fraction without trailing zeros, and the
// rest (the timezone).
fn clock_parts(s string) ?(i64, string, string) {
	if s.len < 8 {
		return none
	}
	h := i64(two_digits(s, 0, 24)?)
	m := i64(two_digits(s[3..], 0, 59)?)
	sec := i64(two_digits(s[6..], 0, 59)?)
	mut k := 8
	mut frac := ''
	if k < s.len && s[k] == `.` {
		start := k + 1
		k++
		for k < s.len && s[k].is_digit() {
			k++
		}
		frac = s[start..k].trim_right('0')
	}
	return h * 3600 + m * 60 + sec, frac, s[k..]
}

fn date_time_key(v string) string {
	year, rest := year_part(v) or { return '' }
	y := astronomical(year) or { return '' }
	month := two_digits(rest[1..], 1, 12) or { return '' }
	day := two_digits(rest[4..], 1, 31) or { return '' }
	secs, frac, tz := clock_parts(rest[7..]) or { return '' }
	return instant_key(y, month, day, secs, frac, tz_minutes(tz))
}

fn date_key(v string) string {
	year, rest := year_part(v) or { return '' }
	y := astronomical(year) or { return '' }
	month := two_digits(rest[1..], 1, 12) or { return '' }
	day := two_digits(rest[4..], 1, 31) or { return '' }
	return instant_key(y, month, day, 0, '', tz_minutes(rest[6..]))
}

// time_key is a time of day, shifted to UTC when it has a timezone and kept within the day.
fn time_key(v string) string {
	secs, frac, tz := clock_parts(v) or { return '' }
	mut s := secs
	mark := if t := tz_minutes(tz) {
		s -= i64(t) * 60
		'Z'
	} else {
		'L'
	}
	s = ((s % 86400) + 86400) % 86400
	return if frac == '' { '${s}${mark}' } else { '${s}.${frac}${mark}' }
}

fn g_key(root Builtin, v string) string {
	match root {
		.g_year_month {
			year, rest := year_part(v) or { return '' }
			y := astronomical(year) or { return '' }
			month := two_digits(rest[1..], 1, 12) or { return '' }
			return instant_key(y, month, 1, 0, '', tz_minutes(rest[3..]))
		}
		.g_year {
			year, rest := year_part(v) or { return '' }
			y := astronomical(year) or { return '' }
			return instant_key(y, 1, 1, 0, '', tz_minutes(rest))
		}
		.g_month_day {
			month := two_digits(v[2..], 1, 12) or { return '' }
			day := two_digits(v[5..], 1, 31) or { return '' }
			return instant_key(1972, month, day, 0, '', tz_minutes(v[7..]))
		}
		.g_day {
			day := two_digits(v[3..], 1, 31) or { return '' }
			return instant_key(1972, 1, day, 0, '', tz_minutes(v[5..]))
		}
		else {
			month := two_digits(v[2..], 1, 12) or { return '' }
			return instant_key(1972, month, 1, 0, '', tz_minutes(v[4..]))
		}
	}
}

// duration_key is a duration as its sign, months and seconds (with the seconds' fraction).
fn duration_key(v string) string {
	neg := v.starts_with('-')
	body := if neg { v[2..] } else { v[1..] }
	mut months, mut secs := i64(0), i64(0)
	mut frac := ''
	mut in_time := false
	mut num := ''
	// Each number with its designator: Y M D before T, H M S after.
	for c in body {
		if c == `T` {
			in_time = true
			continue
		}
		if c.is_digit() || c == `.` {
			num += c.ascii_str()
			continue
		}
		if num.len > 15 {
			return ''
		}
		whole := if num.contains('.') { num.all_before('.') } else { num }
		n := whole.i64()
		match true {
			!in_time && c == `Y` { months += n * 12 }
			!in_time && c == `M` { months += n }
			!in_time && c == `D` { secs += n * 86400 }
			in_time && c == `H` { secs += n * 3600 }
			in_time && c == `M` { secs += n * 60 }
			in_time && c == `S` {
				secs += n
				if num.contains('.') {
					frac = num.all_after('.').trim_right('0')
				}
			}
			else { return '' }
		}
		num = ''
	}
	zero := months == 0 && secs == 0 && frac == ''
	sign := if neg && !zero { '-' } else { '' }
	return if frac == '' { '${sign}${months}M${secs}' } else { '${sign}${months}M${secs}.${frac}' }
}
