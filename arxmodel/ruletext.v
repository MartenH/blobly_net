module arxmodel

import crypto.sha256
import flatxml
import os

// The merge rules as a file: flatxml's rule text (`flatxml.format_rules` writes it and
// `flatxml.parse_rules` reads it), one rule a line in the order the merge uses them, behind a
// header that says where they came from. The file is derived from an AUTOSAR schema, so it is
// made on the user's machine and never committed.

// rules_format is the version of the rules file's format this arxmodel writes and reads. A file
// of another format is refused: its rules are not in the order this one merges and writes by.
pub const rules_format = 3

// version is arxmodel's version, from its own v.mod (builtin.v: @VMOD_FILE would be the v.mod of a
// program that vendors arxmodel).
pub const version = vmod_version(vmod_text)

// flatxml_commit is the flatxml commit vendored, from flatxml/VENDORED.
pub const flatxml_commit = vendored_commit(flatxml_vendored_text)

fn vmod_version(text string) string {
	for line in text.split_into_lines() {
		t := line.trim_space()
		if t.starts_with('version:') {
			return t.all_after(':').trim_space().trim("'")
		}
	}
	return 'unknown'
}

fn vendored_commit(text string) string {
	words := text.fields()
	return if words.len > 1 { words[1] } else { 'unknown' }
}

// Provenance is what a rules file says it was made from.
pub struct Provenance {
pub mut:
	schema        string // the schema's file name (its release)
	namespace     string // the namespace it governs
	schema_path   string
	schema_sha256 string
	arxmodel      string
	flatxml       string
	policy        []string // the policy's settings the rules were made by, `name value` each
}

fn sha256_hex(b []u8) string {
	return sha256.sum(b).hex()
}

// provenance describes the rules made from schema use u, by policy p.
pub fn provenance(u &SchemaUse, p Policy) Provenance {
	bytes := os.read_bytes(u.path) or { []u8{} }
	return Provenance{
		schema:        u.name
		namespace:     u.ns
		schema_path:   os.real_path(u.path)
		schema_sha256: sha256_hex(bytes)
		arxmodel:      version
		flatxml:       flatxml_commit
		policy:        p.rule_settings()
	}
}

// format_rules writes the rules as flatxml's rule text, after a header: where they came from,
// the policy they were made by, every pair in conflict, and the merge settings (the policy's:
// case and attributes by name; the documents' declaration attributes are added when merging).
pub fn format_rules(f Flat, pv Provenance, st Settings) !string {
	mut out := []string{}
	out << '# arxmodel merge rules, generated on this machine from an AUTOSAR schema: do not commit.'
	out << '# format: ${rules_format}'
	out << '# schema: ${pv.schema}'
	out << '# namespace: ${pv.namespace}'
	out << '# schema-path: ${pv.schema_path}'
	out << '# schema-sha256: ${pv.schema_sha256}'
	out << '# arxmodel: ${pv.arxmodel}'
	out << '# flatxml: ${pv.flatxml}'
	for line in pv.policy {
		out << '# policy: ${line}'
	}
	out << '# ignore-declarations: ${if st.ignore_declarations { 'yes' } else { 'no' }}'
	for c in f.conflicts {
		out << '# conflict: ${c.parent} ${c.child} = ${c.rules.join(' ; ')}'
	}
	// roles whose items are identified by a definition: their rules key by it, and a definition
	// given several times is a set, which rule text cannot say
	for r in f.identity_roles {
		out << '# identity: ${r.parent} ${r.items.join(',')} ${r.definition} ${r.label}'.trim_space()
	}
	// the rules (by their number, from 0) of non-splittable roles that must repeat identically,
	// and the elements a merge does not compare
	if f.repeat_rules.len > 0 {
		out << '# repeat: ${f.repeat_rules.map(it.str()).join(' ')}'
	}
	if f.ignored_content.len > 0 {
		out << '# ignore-content: ${f.ignored_content.join(' ')}'
	}
	// the local namespace as a `!local` setting, so `flatxml merge --rules` merges as arxmodel does
	body := flatxml.format_rules(flatxml.RuleSet{
		...f.rules
		fold:         st.fold
		ignore_attrs: st.ignore_attrs
	}) or { return error('the rules cannot be written as flatxml rule text: ${err.msg()}') }
	return out.join('\n') + '\n' + body
}

// parse_rules_file reads a rules file back: the rules, every pair in conflict, its provenance
// and its merge settings.
pub fn parse_rules_file(text string) !(Flat, Provenance, Settings) {
	mut pv := Provenance{}
	mut f := Flat{}
	mut st := Settings{}
	mut format := ''
	for line in text.split_into_lines() {
		if !line.starts_with('# ') {
			continue
		}
		body := line[2..]
		name := body.all_before(':')
		value := body.all_after(':').trim_space()
		match name {
			'format' { format = value }
			'schema' { pv.schema = value }
			'namespace' { pv.namespace = value }
			'schema-path' { pv.schema_path = value }
			'schema-sha256' { pv.schema_sha256 = value }
			'arxmodel' { pv.arxmodel = value }
			'flatxml' { pv.flatxml = value }
			'policy' { pv.policy << value }
			'ignore-declarations' { st.ignore_declarations = value == 'yes' }
			'repeat' {
				f.repeat_rules = value.fields().map(it.int())
			}
			'ignore-content' {
				f.ignored_content = value.fields()
			}
			'identity' {
				w := value.fields()
				if w.len >= 3 {
					f.identity_roles << IdentityRole{
						parent:     w[0]
						items:      w[1].split(',')
						definition: w[2]
						label:      if w.len > 3 { w[3] } else { '' }
					}
				}
			}
			'conflict' {
				pair := value.all_before(' = ')
				f.conflicts << Conflict{
					parent: pair.all_before(' ')
					child:  pair.all_after(' ')
					rules:  value.all_after(' = ').split(' ; ').filter(it != '')
				}
			}
			else {}
		}
	}
	if pv.schema == '' {
		return error('not an arxmodel rules file: no `# schema:` line')
	}
	if format != '${rules_format}' {
		was := if format == '' {
			'an older format (no `# format:` line)'
		} else {
			'format ${format}'
		}
		return error('the rules file is in ${was}; this arxmodel reads format ${rules_format}: make it again with `arxmodel rules --emit`')
	}
	rs := flatxml.parse_rules(text)!
	st.fold = rs.fold
	st.ignore_attrs = rs.ignore_attrs.clone()
	f.rules = flatxml.RuleSet{
		rules:         rs.rules
		local_ns:      rs.local_ns
		written_order: rs.written_order
	}
	f.described = f.rules.rules.map('')
	return f, pv, st
}

// rules_file_check refuses a rules file for documents it does not govern: their one namespace
// must be the file's, and the releases they declare of the file's family; and warns about a
// newer release declared than the file was made from, and about policy settings that differ from
// the file's (the file's apply).
pub fn rules_file_check(sc &Schemas, pv Provenance, st Settings, p Policy) ![]string {
	mut nss := []string{}
	for u in sc.uses {
		if u.ns !in nss {
			nss << u.ns
		}
	}
	if nss.len != 1 {
		return error('${nss.len} namespaces declared; one model has one')
	}
	if nss[0] != pv.namespace {
		return error('the documents declare ${nss[0]}; the rules file governs ${pv.namespace}')
	}
	made := release_of(pv.schema) or {
		return error('the release of ${pv.schema}, which the rules were made from, cannot be read')
	}
	mut family := false
	mut out := []string{}
	for u in sc.uses {
		r := release_of(u.name) or { continue }
		if r.prefix != made.prefix {
			continue
		}
		family = true
		if r.compare(made) > 0 {
			out << '${u.name}, declared by ${u.docs.len} file(s), is newer than ${pv.schema}, which the rules were made from'
		}
	}
	if !family {
		return error("no document declares a release of ${pv.schema}'s family; the rules file does not govern them")
	}
	for line in p.rule_settings() {
		name := line.all_before(' ')
		was := pv.policy.filter(it.all_before(' ') == name)
		if was.len == 0 || was[0] != line {
			made_with := if was.len > 0 { toml_setting(was[0]) } else { '${name} (unset)' }
			out << "the rules were made with `${made_with}`; the policy says `${toml_setting(line)}`; the rules file's applies"
		}
	}
	file_merge := Policy{
		fold:                st.fold
		ignore_attrs:        st.ignore_attrs
		ignore_declarations: st.ignore_declarations
	}.merge_settings()
	for k, line in p.merge_settings() {
		if file_merge[k] != line {
			out << "the rules file says `${toml_setting(file_merge[k])}`; the policy says `${toml_setting(line)}`; the rules file's applies"
		}
	}
	return out
}
