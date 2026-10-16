module arxmodel

import flatxml
import os
import toml

// PolicyCache holds the built-in policy once it is read.
@[heap]
struct PolicyCache {
mut:
	read   bool
	policy Policy
}

// builtin_policy is read on first use, not at start: reading it is work no command needs twice.
const builtin_policy = &PolicyCache{}

// ItemItself is what becomes of the items of a multi-valued role whose split key is the role
// alone, when they have children.
pub enum ItemItself {
	copy          // each a child of its own, never merged ([TPS_GST_00417])
	single_values // keyed by its single-valued element children, and merged by them
}

// PrimitiveValues is what becomes of the values of a multi-valued role of primitive values whose
// split key is the role alone.
pub enum PrimitiveValues {
	copy            // every value of every fragment kept, duplicates too ([TPS_GST_00449])
	merge_identical // a value is its own key: identical values are one
}

// RepeatedContent is what a non-splittable multi-valued role in several fragments may be.
pub enum RepeatedContent {
	identical // the same in each, else a finding ([constr_2524], [TPS_GST_00447])
	copy      // each occurrence kept (a key met twice is a collision)
}

// AbstractItems is how the items of a role of several item types are keyed.
pub enum AbstractItems {
	@union   // every type by the union of the types' key parts ([TPS_GST_00416])
	per_kind // each type by its own
}

// Policy is every merge choice that is arxmodel's rather than the schema's (policy.toml).
pub struct Policy {
pub mut:
	absent_keys              flatxml.Keyless = .own
	fold                     bool
	ignore_attrs             []string
	ignore_declarations      bool = true
	item_itself              ItemItself
	primitive_values         PrimitiveValues
	repeated_content         RepeatedContent
	abstract_items           AbstractItems
	ignore_structured        bool = true // FILE-INFO-COMMENT and the like not compared
	repeated_choice_as_mixed bool = true
	package_element          string = 'AR-PACKAGE'
	// roles whose items are identified by one role of theirs (`Class.role` -> role), in place of
	// their single-valued children
	item_identity map[string]string
	// a finding's severity by `layer`, `layer.kind` or `layer.kind:what`; error where unset
	severities map[string]Severity
	// [[filter]]: severities for the findings each matches, after severities, first match wins
	filters []Filter
	source  string // where it was read: `built-in`, `automat`, or a path
}

// default_policy is the built-in policy.toml.
pub fn default_policy() Policy {
	mut c := unsafe { builtin_policy }
	if !c.read {
		mut p := parse_policy(default_policy_text) or { panic('the built-in policy.toml: ${err}') }
		p.source = 'built-in (the AUTOSAR specification)'
		c.policy = p
		c.read = true
	}
	return c.policy
}

// automat_policy is the built-in automat.policy.toml.
pub fn automat_policy() Policy {
	mut p := parse_policy(automat_policy_text) or { panic('the built-in automat.policy.toml: ${err}') }
	p.source = 'automat (built in)'
	return p
}

// named_policy is a policy by name (`spec`, the default; `automat`) or a file path.
pub fn named_policy(name string) !Policy {
	match name {
		'', 'spec' {
			return default_policy()
		}
		'automat' {
			return automat_policy()
		}
		else {
			text := os.read_file(name) or { return error('${name}: ${err.msg()}') }
			mut p := parse_policy(text) or { return error('${name}: ${err.msg()}') }
			p.source = name
			return p
		}
	}
}

// rule_settings are the settings a rule set is made by, `name value` each: a rules file is made
// by them and keeps them.
pub fn (p Policy) rule_settings() []string {
	mut out := []string{}
	for st in policy_settings() {
		if st.rules {
			out << '${st.key} ${st.words(p)}'.trim_space()
		}
	}
	return out
}

// words is a setting's value as a rules file records it: a choice or a boolean as its word, a
// table as sorted `Class.role=role` words.
fn (st &PolicySetting) words(p Policy) string {
	v := st.show(p)
	return match st.kind {
		.table { v.trim('{} ').split(', ').filter(it != '').map(it.replace('" = "', '=').trim('"')).join(' ') }
		.names { v.trim('[]').split(', ').filter(it != '').map(it.trim('"')).join(' ') }
		else { v.trim('"') }
	}
}

// merge_settings are the settings a merge applies, `name value` each.
pub fn (p Policy) merge_settings() []string {
	return [
		'key_case ${if p.fold { 'ignore' } else { 'exact' }}',
		'ignore_attrs ${p.ignore_attrs.join(' ')}'.trim_space(),
		'ignore_declarations ${if p.ignore_declarations { 'yes' } else { 'no' }}',
	]
}

// SettingKind is the kind of value a setting takes.
pub enum SettingKind {
	choice  // one of `allowed`
	boolean // true or false
	names   // a list of attribute names
	element // an element name
	table   // a table of "Class.role" = "role"
}

// PolicySetting is one setting of a policy: where it is, what it takes, what it means and the
// specification item it concerns, and how it is read and shown.
pub struct PolicySetting {
pub:
	table       string
	key         string
	kind        SettingKind
	allowed     []string // choice: the values, the specification's first where one is
	description string
	spec        string // the specification items the choice concerns
	rules       bool   // a rule set is made by it, so a rules file records it
mut:
	choose fn (mut p Policy, value string) = unsafe { nil } // choice and boolean ('true', 'false')
	read   fn (mut p Policy, name string, v toml.Any) ! = unsafe { nil } // the others
	show   fn (p Policy) string = unsafe { nil } // the value, as TOML
}

// value is a setting's value in a policy, as TOML.
pub fn (st &PolicySetting) value(p Policy) string {
	return st.show(p)
}

// policy_diff is how policy q differs from p: each setting and severity, `[table] key: a -> b`.
pub fn policy_diff(p Policy, q Policy) []string {
	mut out := []string{}
	for st in policy_settings() {
		a, b := st.show(p), st.show(q)
		if a != b {
			out << '[${st.table}] ${st.key}: ${a} -> ${b}'
		}
	}
	mut keys := p.severities.keys()
	for k in q.severities.keys() {
		if k !in keys {
			keys << k
		}
	}
	keys.sort()
	for k in keys {
		a := if s := p.severities[k] { '"${s}"' } else { '(unset)' }
		b := if s := q.severities[k] { '"${s}"' } else { '(unset)' }
		if a != b {
			out << '[severity] "${k}": ${a} -> ${b}'
		}
	}
	// filters, by place
	for k in 0 .. max_int(p.filters.len, q.filters.len) {
		a := if k < p.filters.len { p.filters[k].toml() } else { '(none)' }
		b := if k < q.filters.len { q.filters[k].toml() } else { '(none)' }
		if a != b {
			out << '[[filter]] ${k + 1}: ${a} -> ${b}'
		}
	}
	return out
}

fn max_int(a int, b int) int {
	return if a > b { a } else { b }
}

fn yes(b bool) string {
	return if b { 'true' } else { 'false' }
}

// policy_settings are every setting a policy has, each required: the one list the parser, the
// rules file, `arxmodel policy` and policy.schema.json read.
pub fn policy_settings() []PolicySetting {
	return [
		PolicySetting{
			table:       'merge'
			key:         'absent_keys'
			kind:        .choice
			allowed:     ['own', 'empty']
			rules:       true
			spec:        'TPS_GST_00417'
			description: 'An item whose split key parts are all absent: "own" keeps it an item of its own; "empty" gives it the one empty key of its aggregation, so such items merge.'
			choose:      fn (mut p Policy, v string) {
				p.absent_keys = if v == 'own' { flatxml.Keyless.own } else { .empty }
			}
			show:        fn (p Policy) string {
				return if p.absent_keys == .own { '"own"' } else { '"empty"' }
			}
		},
		PolicySetting{
			table:       'merge'
			key:         'key_case'
			kind:        .choice
			allowed:     ['exact', 'ignore']
			spec:        'TPS_GST_00021, constr_2508'
			description: 'Keys compared as written ("exact"; keys of one aggregation that differ only in case are reported, merge.case_only) or ignoring ASCII case ("ignore").'
			choose:      fn (mut p Policy, v string) {
				p.fold = v == 'ignore'
			}
			show:        fn (p Policy) string {
				return if p.fold { '"ignore"' } else { '"exact"' }
			}
		},
		PolicySetting{
			table:       'merge'
			key:         'ignore_attrs'
			kind:        .names
			description: 'Attributes whose values may differ between the fragments of one element.'
			read:        read_ignore_attrs
			show:        fn (p Policy) string {
				return '[' + p.ignore_attrs.map('"${it}"').join(', ') + ']'
			}
		},
		PolicySetting{
			table:       'merge'
			key:         'ignore_declarations'
			kind:        .boolean
			description: 'Namespace declarations and xsi: attributes may differ between fragments.'
			choose:      fn (mut p Policy, v string) {
				p.ignore_declarations = v == 'true'
			}
			show:        fn (p Policy) string {
				return yes(p.ignore_declarations)
			}
		},
		PolicySetting{
			table:       'merge'
			key:         'item_itself'
			kind:        .choice
			allowed:     ['copy', 'single_values']
			rules:       true
			spec:        'TPS_GST_00417'
			description: 'Items with children of a multi-valued role whose split key is the role alone: "copy" keeps each, never merged; "single_values" keys them by their single-valued element children.'
			choose:      fn (mut p Policy, v string) {
				p.item_itself = if v == 'copy' { ItemItself.copy } else { .single_values }
			}
			show:        fn (p Policy) string {
				return if p.item_itself == .copy { '"copy"' } else { '"single_values"' }
			}
		},
		PolicySetting{
			table:       'merge'
			key:         'primitive_values'
			kind:        .choice
			allowed:     ['copy', 'merge_identical']
			rules:       true
			spec:        'TPS_GST_00449'
			description: 'Values of a multi-valued role of primitive values whose split key is the role alone: "copy" keeps every value of every fragment, duplicates too; "merge_identical" makes identical values one.'
			choose:      fn (mut p Policy, v string) {
				p.primitive_values = if v == 'copy' {
					PrimitiveValues.copy
				} else {
					.merge_identical
				}
			}
			show:        fn (p Policy) string {
				return if p.primitive_values == .copy { '"copy"' } else { '"merge_identical"' }
			}
		},
		PolicySetting{
			table:       'merge'
			key:         'repeated_content'
			kind:        .choice
			allowed:     ['identical', 'copy']
			rules:       true
			spec:        'constr_2524, TPS_GST_00447'
			description: 'A non-splittable multi-valued role in several fragments: "identical" allows it only as an identical repetition (one copy kept; else merge.repeated_differs); "copy" keeps each occurrence (a key met twice is a collision).'
			choose:      fn (mut p Policy, v string) {
				p.repeated_content = if v == 'identical' {
					RepeatedContent.identical
				} else {
					.copy
				}
			}
			show:        fn (p Policy) string {
				return if p.repeated_content == .identical { '"identical"' } else { '"copy"' }
			}
		},
		PolicySetting{
			table:       'merge'
			key:         'abstract_items'
			kind:        .choice
			allowed:     ['union', 'per_kind']
			rules:       true
			spec:        'TPS_GST_00416'
			description: 'The items of a role of several item types: "union" keys every type by the union of the types\' key parts; "per_kind" keys each type by its own.'
			choose:      fn (mut p Policy, v string) {
				p.abstract_items = if v == 'union' { AbstractItems.@union } else { .per_kind }
			}
			show:        fn (p Policy) string {
				return if p.abstract_items == .@union { '"union"' } else { '"per_kind"' }
			}
		},
		PolicySetting{
			table:       'merge'
			key:         'item_identity'
			kind:        .table
			rules:       true
			description: 'Roles whose items are identified by one role of theirs ("Class.role" = "role"), in place of their split key; a definition given several times is a set told apart by content.'
			read:        read_item_identity
			show:        fn (p Policy) string {
				mut parts := []string{}
				for role, by in p.item_identity {
					parts << '"${role}" = "${by}"'
				}
				parts.sort()
				return '{ ' + parts.join(', ') + ' }'
			}
		},
		PolicySetting{
			table:       'merge'
			key:         'repeated_choice_as_mixed'
			kind:        .boolean
			rules:       true
			description: 'A class whose element-only content repeats its roles through a repeated choice is counted like mixed content.'
			choose:      fn (mut p Policy, v string) {
				p.repeated_choice_as_mixed = v == 'true'
			}
			show:        fn (p Policy) string {
				return yes(p.repeated_choice_as_mixed)
			}
		},
		PolicySetting{
			table:       'merge'
			key:         'file_info_comment'
			kind:        .choice
			allowed:     ['ignore', 'compare']
			rules:       true
			spec:        'TPS_GST_00382'
			description: 'A structured comment (atpStructuredComment, FILE-INFO-COMMENT): "ignore" leaves its differences between fragments unreported; "compare" compares it like any content.'
			choose:      fn (mut p Policy, v string) {
				p.ignore_structured = v == 'ignore'
			}
			show:        fn (p Policy) string {
				return if p.ignore_structured { '"ignore"' } else { '"compare"' }
			}
		},
		PolicySetting{
			table:       'schema'
			key:         'governing'
			kind:        .choice
			allowed:     ['newest_declared']
			rules:       true
			description: 'Which release governs a model whose files declare several: the newest declared, or the newest at hand.'
			choose:      fn (mut _ Policy, _ string) {}
			show:        fn (_ Policy) string {
				return '"newest_declared"'
			}
		},
		PolicySetting{
			table:       'schema'
			key:         'splittable'
			kind:        .choice
			allowed:     ['schema']
			rules:       true
			description: 'Splittability exactly where the schema says atpSplitable.'
			choose:      fn (mut _ Policy, _ string) {}
			show:        fn (_ Policy) string {
				return '"schema"'
			}
		},
		PolicySetting{
			table:       'references'
			key:         'package_element'
			kind:        .element
			description: 'The element that is a package: a missing target whose nearest existing ancestor is one is external, else unresolved.'
			read:        read_package_element
			show:        fn (p Policy) string {
				return '"${p.package_element}"'
			}
		},
	]
}

fn read_ignore_attrs(mut p Policy, name string, v toml.Any) ! {
	if v !is []toml.Any {
		return error('policy: `${name}` takes a list of attribute names, not ${show_value(v)}')
	}
	mut attrs := []string{}
	for a in v.array() {
		if a !is string || !xml_name(a.string()) {
			return error('policy: `${name}`: ${show_value(a)} is not an attribute name')
		}
		attrs << a.string()
	}
	// the names are written into a rules file: what flatxml's writer refuses is refused here
	flatxml.format_rules(flatxml.RuleSet{ ignore_attrs: attrs }) or {
		return error('policy: `${name}`: ${err.msg()}')
	}
	p.ignore_attrs = attrs
}

fn read_item_identity(mut p Policy, name string, v toml.Any) ! {
	if v !is map[string]toml.Any {
		return error('policy: `${name}` takes a table of "Class.role" = "role", not ${show_value(v)}')
	}
	for role, by in v.as_map() {
		if role.count('.') != 1 || role.starts_with('.') || role.ends_with('.') {
			return error('policy: `${name}`: "${role}" is not a role, Class.role')
		}
		if by !is string || by.string() == '' || by.string().contains_any(' .') {
			return error('policy: `${name}`: "${role}" takes a role name, not ${show_value(by)}')
		}
		p.item_identity[role] = by.string()
	}
}

fn read_package_element(mut p Policy, name string, v toml.Any) ! {
	if v !is string || !xml_name(v.string()) {
		return error('policy: `${name}` takes an element name, not ${show_value(v)}')
	}
	p.package_element = v.string()
}

// parse_policy reads a policy, a TOML document: a table for each table of policy_settings, every
// setting given with a value this build supports, and a severity table. Anything else is refused,
// named.
pub fn parse_policy(text string) !Policy {
	doc := toml.parse_text(text) or {
		if hint := unquoted_severity_key(text) {
			return error('policy: severity key `${hint}` has a dot: quote it, "${hint}" = ...')
		}
		return error('policy: ${err.msg()}')
	}
	top := doc.to_any().as_map()
	settings := policy_settings()
	mut tables := ['severity']
	for st in settings {
		if st.table !in tables {
			tables << st.table
		}
	}
	for key, v in top {
		if key == 'filter' {
			continue
		}
		if v is map[string]toml.Any {
			if key !in tables {
				return error('policy: unknown table [${key}]')
			}
			continue
		}
		for st in settings {
			if st.key == key {
				return error('policy: `${key}` is outside its table; it belongs in [${st.table}]')
			}
		}
		return error('policy: unknown setting `${key}`, outside any table')
	}
	mut p := Policy{}
	for table in tables {
		if table == 'severity' {
			continue
		}
		t := top[table] or { return error('policy: no table [${table}]') }
		m := t.as_map()
		for k, _ in m {
			if !settings.any(it.table == table && it.key == k) {
				return error('policy: unknown setting `${table}.${k}`')
			}
		}
	}
	for st in settings {
		v := top[st.table] or { toml.Any(toml.Null{}) }.as_map()[st.key] or {
			return error('policy: `${st.table}.${st.key}` is not set')
		}
		name := '${st.table}.${st.key}'
		match st.kind {
			.choice { st.choose(mut p, one_of(name, v, st.allowed)!) }
			.boolean { st.choose(mut p, yes(boolean(name, v)!)) }
			else { st.read(mut p, name, v)! }
		}
	}
	if fs := top['filter'] {
		p.filters = read_filters(fs)!
	}
	if sev := top['severity'] {
		for key, v in sev.as_map() {
			if v is map[string]toml.Any {
				return error('policy: severity `${key}` is a table; quote a key with a dot, as "${key}.kind"')
			}
			value := one_of('severity "${key}"', v, ['error', 'warning', 'ignore'])!
			check_severity_key(key)!
			p.severities[key] = match value {
				'error' { Severity.error }
				'warning' { Severity.warning }
				else { Severity.ignore }
			}
		}
	}
	return p
}

// check_severity_key refuses a severity key that names no layer, no kind of its layer, or an
// element or attribute that is not an XML name (`@` before an attribute's).
fn check_severity_key(key string) ! {
	layer := key.all_before('.').all_before(':')
	kinds := known_kinds[layer] or { return error('policy: severity `${key}`: no layer `${layer}`') }
	if !key.contains('.') {
		if key.contains(':') {
			return error('policy: severity `${key}`: an element or attribute needs a kind')
		}
		return
	}
	kind := key.all_after('.').all_before(':')
	if kind !in kinds {
		return error('policy: severity `${key}`: no kind `${kind}` in layer ${layer}')
	}
	if key.contains(':') {
		what := key.all_after(':')
		name := if what.starts_with('@') { what[1..] } else { what }
		if !xml_name(name) && !expanded_name(name) {
			return error('policy: severity `${key}`: `${what}` is not an element name or an @attribute name')
		}
	}
}

// unquoted_severity_key finds, when a policy does not parse, a dotted key under [severity] that is
// not quoted: TOML reads `merge.too_many` as a table, which fails where `merge` has a value.
fn unquoted_severity_key(text string) ?string {
	mut in_severity := false
	for raw in text.split_into_lines() {
		line := raw.all_before('#').trim_space()
		if line.starts_with('[') {
			in_severity = line == '[severity]'
			continue
		}
		if !in_severity || !line.contains('=') {
			continue
		}
		key := line.all_before('=').trim_space()
		if !key.starts_with('"') && !key.starts_with("'") && key.contains('.') {
			return key
		}
	}
	return none
}

// xml_name reports whether s is an XML name (ASCII letters, digits, `_`, `-`, `.`, `:`, and any
// character beyond ASCII; not starting with a digit, `-` or `.`).
// expanded_name reports whether s is an expanded name, `{uri}local`, as a merge names an element
// or attribute of a namespace (flatxml's local_ns, Doc.attr_id): a finding about one is selected so.
fn expanded_name(s string) bool {
	if !s.starts_with('{') {
		return false
	}
	e := s.index_u8(`}`)
	return e > 0 && xml_name(s[e + 1..])
}

fn xml_name(s string) bool {
	if s == '' {
		return false
	}
	for i, c in s {
		if c >= 0x80 || c.is_letter() || c == `_` || c == `:` {
			continue
		}
		if i > 0 && (c.is_digit() || c == `-` || c == `.`) {
			continue
		}
		return false
	}
	return true
}

// toml_setting is a `name value` setting, as a rules file records it, in the policy file's
// spelling: `[merge] repeated_choice_as_mixed = false`.
pub fn toml_setting(line string) string {
	name := line.all_before(' ')
	value := if line.contains(' ') { line.all_after(' ') } else { '' }
	mut table := ''
	for st in policy_settings() {
		if st.key == name {
			table = st.table
		}
	}
	if table == '' {
		return line
	}
	mut kind := SettingKind.choice
	for st in policy_settings() {
		if st.key == name {
			kind = st.kind
		}
	}
	shown := match kind {
		.boolean {
			if value in ['yes', 'true'] {
				'true'
			} else if value in ['no', 'false'] {
				'false'
			} else {
				'"${value}"'
			}
		}
		.names {
			'[' + value.fields().map('"' + it + '"').join(', ') + ']'
		}
		.table {
			'{ ' + value.fields().map('"${it.all_before('=')}" = "${it.all_after('=')}"').join(', ') +
				' }'
		}
		else {
			'"${value}"'
		}
	}
	return '[${table}] ${name} = ${shown}'
}

// one_of is a string setting's value, refused unless it is one of allowed.
fn one_of(name string, v toml.Any, allowed []string) !string {
	if v !is string || v.string() !in allowed {
		return error('policy: `${name}` takes one of ${allowed.map('"' + it + '"').join(', ')}, not ${show_value(v)}')
	}
	return v.string()
}

// boolean is a boolean setting's value, refused unless it is true or false.
fn boolean(name string, v toml.Any) !bool {
	if v !is bool {
		return error('policy: `${name}` takes true or false, not ${show_value(v)}')
	}
	return v.bool()
}

fn show_value(v toml.Any) string {
	return if v is string { '"${v}"' } else { v.to_toml() }
}
