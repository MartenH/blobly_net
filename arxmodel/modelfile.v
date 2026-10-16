module arxmodel

import os
import toml

// A model file describes one model for a program that opens it by name: the files it is made of
// and what they are merged by, so the input set and the schema are stated once, beside the model,
// rather than on every command line.
//
//   # system.arxmodel.toml
//   paths      = ["system/", "extracts/*.arxml", "@more.txt"] # the input set (see `load`)
//   exclude    = ["system/old/*.arxml"]                       # file globs left out
//   schema_dir = "/opt/autosar/schemas" # where the schemas the files declare are
//   rules      = "autosar.rules.txt"    # or a rules file made from one (`rules --emit`)
//   policy     = "spec"                 # `spec` (the default), `automat`, or a policy file
//
// Paths, globs, `@FILE` lists, excludes and files named in it are read from the file's own
// directory when relative. `paths` is required; with neither `schema_dir` nor `rules`, the schema
// directory is this machine's (`configured_schema_dir`), else the built-in identity rules.
// An unknown key, or a value of the wrong type, is refused by name.

// model_file_suffix is how a model file is named, so a program can tell it from an ARXML file.
pub const model_file_suffix = '.arxmodel.toml'

// ModelFile is a model file, read: every path resolved against the file's directory.
pub struct ModelFile {
pub:
	path       string
	paths      []string
	exclude    []string
	schema_dir string
	rules      string
	policy     string
}

// is_model_file reports whether a path names a model file.
pub fn is_model_file(path string) bool {
	return path.to_lower().ends_with(model_file_suffix)
}

// load_model_file reads the model file at path.
pub fn load_model_file(path string) !ModelFile {
	text := os.read_file(path) or { return error('${path}: ${err.msg()}') }
	return parse_model_file(text, path)
}

// parse_model_file reads a model file's text; path is where it is, which relative paths are read
// from, and what messages name.
pub fn parse_model_file(text string, path string) !ModelFile {
	doc := toml.parse_text(text) or { return error('${path}: ${err.msg()}') }
	base := os.dir(path)
	mut paths := []string{}
	mut exclude := []string{}
	mut schema_dir, mut rules, mut policy := '', '', ''
	for k, v in doc.to_any().as_map() {
		match k {
			'paths' { paths = model_strings(v, k, path)!.map(from_dir(base, it)) }
			'exclude' { exclude = model_strings(v, k, path)!.map(from_dir(base, it)) }
			'schema_dir' { schema_dir = from_dir(base, model_string(v, k, path)!) }
			'rules' { rules = from_dir(base, model_string(v, k, path)!) }
			'policy' {
				policy = model_string(v, k, path)!
				if policy !in ['spec', 'automat'] {
					policy = from_dir(base, policy)
				}
			}
			else { return error('${path}: unknown setting `${k}`') }
		}
	}
	if paths.len == 0 {
		return error('${path}: `paths` names no file')
	}
	if schema_dir != '' && rules != '' {
		return error('${path}: `schema_dir` and `rules` both given; the model is merged by one')
	}
	return ModelFile{
		path:       path
		paths:      paths
		exclude:    exclude
		schema_dir: schema_dir
		rules:      rules
		policy:     policy
	}
}

// options are the options the model file opens with: its schema directory, else this machine's.
pub fn (mf ModelFile) options() !OpenOptions {
	mut dir := mf.schema_dir
	if dir == '' && mf.rules == '' {
		dir, _ = configured_schema_dir()!
	}
	return OpenOptions{
		exclude:    mf.exclude
		schema_dir: dir
		rules_file: mf.rules
		policy:     mf.policy
	}
}

// open opens the model the file describes.
pub fn (mf ModelFile) open() !&Opened {
	return open(mf.paths, mf.options()!)
}

// from_dir is a path of a model file read from its directory: as it is when absolute; an
// `@FILE` list the same way.
fn from_dir(base string, p string) string {
	if p.starts_with('@') {
		return '@' + from_dir(base, p[1..])
	}
	return if os.is_abs_path(p) { p } else { os.join_path(base, p) }
}

fn model_string(v toml.Any, key string, path string) !string {
	if v !is string || v.string() == '' {
		return error('${path}: `${key}` takes a string')
	}
	return v.string()
}

fn model_strings(v toml.Any, key string, path string) ![]string {
	if v !is []toml.Any {
		return error('${path}: `${key}` takes a list of strings')
	}
	mut out := []string{}
	for x in v.array() {
		if x !is string || x.string() == '' {
			return error('${path}: `${key}` takes a list of strings')
		}
		out << x.string()
	}
	return out
}
