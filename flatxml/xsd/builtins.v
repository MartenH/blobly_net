module xsd

// Builtin is one of XSD 1.0's built-in simple types (Part 2, section 3), in the order of
// `builtin_names`.
pub enum Builtin {
	any_simple_type
	string
	boolean
	decimal
	float
	double
	duration
	date_time
	time
	date
	g_year_month
	g_year
	g_month_day
	g_day
	g_month
	hex_binary
	base64_binary
	any_uri
	qname
	notation
	normalized_string
	token
	language
	nmtoken
	nmtokens
	name
	nc_name
	id
	idref
	idrefs
	entity
	entities
	integer
	non_positive_integer
	negative_integer
	long
	int
	short
	byte
	non_negative_integer
	unsigned_long
	unsigned_int
	unsigned_short
	unsigned_byte
	positive_integer
}

const builtin_names = ['anySimpleType', 'string', 'boolean', 'decimal', 'float', 'double', 'duration',
	'dateTime', 'time', 'date', 'gYearMonth', 'gYear', 'gMonthDay', 'gDay', 'gMonth', 'hexBinary',
	'base64Binary', 'anyURI', 'QName', 'NOTATION', 'normalizedString', 'token', 'language',
	'NMTOKEN', 'NMTOKENS', 'Name', 'NCName', 'ID', 'IDREF', 'IDREFS', 'ENTITY', 'ENTITIES',
	'integer', 'nonPositiveInteger', 'negativeInteger', 'long', 'int', 'short', 'byte',
	'nonNegativeInteger', 'unsignedLong', 'unsignedInt', 'unsignedShort', 'unsignedByte',
	'positiveInteger']

fn builtin_named(local string) ?Builtin {
	i := builtin_names.index(local)
	if i < 0 {
		return none
	}
	return unsafe { Builtin(i) }
}

// builtin_name is the XSD name of a built-in type (`unsignedInt`).
pub fn builtin_name(b Builtin) string {
	return builtin_names[int(b)]
}

// is_integer: integer and the types derived from it, which the enumeration orders together.
fn is_integer(b Builtin) bool {
	return int(b) >= int(Builtin.integer) && int(b) <= int(Builtin.positive_integer)
}

// string_like: string and the types derived from it (normalizedString up to ENTITIES, ordered
// together), the only family whose whiteSpace may be other than collapse.
fn string_like(b Builtin) bool {
	return b in [.string, .any_simple_type]
		|| (int(b) >= int(Builtin.normalized_string) && int(b) <= int(Builtin.entities))
}

// length_applies: the types the length facets apply to.
fn length_applies(b Builtin) bool {
	return string_like(b) || b in [.any_uri, .qname, .notation, .hex_binary, .base64_binary]
}

fn is_temporal(b Builtin) bool {
	return int(b) >= int(Builtin.duration) && int(b) <= int(Builtin.g_month)
}
