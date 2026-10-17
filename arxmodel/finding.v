module arxmodel

// Layer is what a finding comes from.
pub enum Layer {
	merge        // putting the files together by the merge rules
	xml_schema   // one file against its XML schema
	multiplicity // a role's count in the merged model against the meta-model's
	reference    // a reference against the element at its path
	policy       // the policy itself: a filter that matched nothing
}

// Severity is what a finding means for a check: an error fails it, a warning is said, an
// ignored finding is only counted.
pub enum Severity {
	error
	warning
	ignore
}

// Finding is one thing a check found, in any layer: the layer, its kind, its severity (from the
// policy), the element it is about (a path), what it says, and every place in the files it
// involves (`file:line:column`).
pub struct Finding {
pub:
	layer Layer
	kind  string
	what  string // the element or `@attribute` concerned, where the kind has one
	// a merge problem on an element pair in conflict: judged by a rule that may not be the pair's
	in_conflict bool
	severity    Severity
	path        string
	message     string
	at          []string
	// a reference finding: the reference's BASE and DEST attributes, which a filter may match
	base string
	dest string
	// the filter that set the severity (its number in the policy, from 1; 0 for none), its
	// reason, and the severity the policy's [severity] gave before it
	filter int
	reason string
	was    Severity
}

pub fn (f Finding) str() string {
	return '${f.severity}: ${f.layer}.${f.kind}${if f.in_conflict { ' (in conflict)' } else { '' }}: ${f.message}: ${f.path}${if f.at.len > 0 {
		' at ' + f.at.join(', ')
	} else {
		''
	}}'
}

// severity is the policy's severity for a finding: the setting for its layer, kind and what
// (`merge.value_differs:@DEST`), else for its layer and kind, else for its layer; an error where
// the policy says nothing.
pub fn (p Policy) severity(layer Layer, kind string, what string) Severity {
	if what != '' {
		if s := p.severities['${layer}.${kind}:${what}'] {
			return s
		}
	}
	if s := p.severities['${layer}.${kind}'] {
		return s
	}
	// what the policy says nothing of is an error, but for the policy's own findings: a warning
	return p.severities['${layer}'] or {
		if layer == .policy { Severity.warning } else { Severity.error }
	}
}

// merge_severity is a merge problem's severity: a line for its kind (and what) applies whether
// or not the problem lies on a pair in conflict; else, for one in conflict, `merge.in_conflict`;
// else the layer's.
pub fn (p Policy) merge_severity(kind string, what string, in_conflict bool) Severity {
	if what != '' {
		if s := p.severities['merge.${kind}:${what}'] {
			return s
		}
	}
	if s := p.severities['merge.${kind}'] {
		return s
	}
	if in_conflict {
		if s := p.severities['merge.in_conflict'] {
			return s
		}
	}
	return p.severities['merge'] or { Severity.error }
}

// known_kinds are the kinds of finding each layer has, which a key of the policy's [severity]
// table may name.
pub const known_kinds = {
	'merge':        ['collision', 'key_reused', 'ordered_split', 'too_many', 'value_differs',
		'name_differs', 'missing_key', 'conflict', 'in_conflict', 'case_only', 'repeated_differs']
	'xml_schema':   ['undeclared_element', 'undeclared_attribute', 'missing_attribute',
		'text_not_allowed', 'children_not_allowed', 'abstract_type', 'not_nillable', 'invalid_value',
		'duplicate_id', 'unknown_idref', 'unbound_prefix', 'unexpected_element', 'missing_element',
		'unsupported', 'not_checked']
	'multiplicity': ['below_min', 'above_max']
	'policy':       ['unused_filter']
	'reference':    ['unresolved', 'external', 'wrong_kind', 'case_mismatch', 'empty', 'relative',
		'duplicate_path']
}
