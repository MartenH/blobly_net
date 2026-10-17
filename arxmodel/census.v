module arxmodel

import flatxml.xsd

// Census accounts for every annotation of a schema, by what the rule reader did with it: used
// to make a rule, compared with the schema's structure, a tag of a kind the reader uses but
// found where it does not read it, or any other annotation. Nothing is dropped without being
// counted, and nothing is classified by a list of the schema's own vocabulary: what the reader
// does not use is `other`, counted per name as the user's schema has it.
pub struct Census {
pub mut:
	appinfo   int
	used      map[string]int // applied to a rule
	checked   map[string]int // compared with the schema's structure
	not_read  map[string]int // a tag the reader uses, where it does not read it, by owner
	other     map[string]int // every other tag, stereotype and appinfo source
	malformed []string       // tag text that is not `key="value"`
	notes     map[string]int // facts worth counting
	problems  map[string]int // annotations that could not be applied, by kind
}

// The tags and stereotypes the reader applies to a role (an element declaration it makes a rule
// of); an attribute role's name is used for split keys. The wrapper tag is also checked.
const role_tags = ['mmt.qualifiedName', 'atp.Splitkey', 'pureMM.maxOccurs', 'pureMM.minOccurs',
	'pureMM.isOrdered', 'xml.roleElement', 'xml.typeElement']
const role_stereotypes = ['atpSplitable', structured_comment]
// What the reader applies to a role written as an attribute: its name, for split keys.
const attribute_role_tags = ['mmt.qualifiedName']
// A class's stereotype the reader applies: a reference to an instance is keyed by its children.
const instance_ref_stereotype = 'instanceRef'
const type_stereotypes = [instance_ref_stereotype]
const checked_tags = ['xml.roleWrapperElement']

// take_census counts every annotation by what was done with it.
fn (mut rs RuleSet) take_census() {
	for a in rs.schema.appinfo {
		rs.census.appinfo++
		// a role is an element declaration a rule was made of
		role := a.owner == .element && a.idx in rs.by_decl
		attr_role := a.owner == .attribute && a.idx in rs.attr_ann
			&& 'mmt.qualifiedName' in rs.attr_ann[a.idx].tags
		match a.source {
			'tags' {
				tags, bad := parse_tags(a.text)
				rs.census.malformed << bad
				for t in tags {
					rs.census.count_tag(t.key, a.owner, role, attr_role)
				}
			}
			'stereotypes' {
				for x in parse_stereotypes(a.text) {
					if x in type_stereotypes && a.owner == .complex_type {
						rs.census.used['stereotype ${x}']++
					} else if x in type_stereotypes {
						rs.census.not_read['stereotype ${x} on ${a.owner}']++
					} else if x in role_stereotypes {
						if role {
							rs.census.used['stereotype ${x}']++
						} else {
							rs.census.not_read['stereotype ${x} on ${a.owner}']++
						}
					} else {
						rs.census.other['stereotype ${x}']++
					}
				}
			}
			else {
				rs.census.other['source ${a.source}']++
			}
		}
	}
}

fn (mut c Census) count_tag(key string, owner xsd.OwnerKind, role bool, attr_role bool) {
	if key in checked_tags && role {
		c.checked['tag ${key}']++
	} else if key in role_tags || key in checked_tags {
		if role || (attr_role && key in attribute_role_tags) {
			c.used['tag ${key}']++
		} else {
			c.not_read['tag ${key} on ${owner}']++
		}
	} else {
		c.other['tag ${key}']++
	}
}

fn (mut c Census) note(what string) {
	c.notes[what]++
}

fn (mut c Census) problem(kind string) {
	c.problems[kind]++
}
