module arxmodel

// Tag is one `key="value"` pair of a schema annotation's tag list.
pub struct Tag {
pub:
	key   string
	value string
}

// parse_tags reads an annotation's tag list, `k1="v1";k2="v2"`. A value runs to its closing
// quote, so it may hold `;`. What is not a key followed by a quoted value is returned as
// malformed text rather than dropped.
pub fn parse_tags(text string) ([]Tag, []string) {
	mut tags := []Tag{}
	mut bad := []string{}
	mut k := 0
	for k < text.len {
		// skip separators between pairs
		for k < text.len && (text[k] == `;` || text[k].is_space()) {
			k++
		}
		if k >= text.len {
			break
		}
		start := k
		eq := text.index_after('=', k) or { -1 }
		if eq < 0 || eq + 1 >= text.len || text[eq + 1] != `"` {
			// no `="` ahead: the rest, up to the next separator, is not a pair
			end := text.index_after(';', k) or { text.len }
			bad << text[start..end].trim_space()
			k = end
			continue
		}
		key := text[k..eq].trim_space()
		close := text.index_after('"', eq + 2) or { -1 }
		if close < 0 || key == '' || key.contains(';') {
			end := text.index_after(';', k) or { text.len }
			bad << text[start..end].trim_space()
			k = end
			continue
		}
		tags << Tag{
			key:   key
			value: decode_entities(text[eq + 2..close])
		}
		k = close + 1
	}
	return tags, bad
}

// parse_stereotypes reads a comma-separated stereotype list.
pub fn parse_stereotypes(text string) []string {
	mut out := []string{}
	for s in decode_entities(text).split(',') {
		t := s.trim_space()
		if t != '' {
			out << t
		}
	}
	return out
}

// decode_entities undoes the escaping an appinfo's text is written back with.
fn decode_entities(s string) string {
	if !s.contains('&') {
		return s
	}
	return s.replace_each(['&lt;', '<', '&gt;', '>', '&quot;', '"', '&apos;', "'", '&amp;', '&'])
}
