module arxmodel

import os
import toml

// The user's configuration: where the AUTOSAR schemas are on this machine, so local runs read the
// exact rules while CI, which has no schema, reads the built-in ones.

// enoent is the errno of a path that does not exist (the same on Linux, macOS and Windows).
const enoent = 2

// schema_dir_env names the environment variable giving the schema directory.
pub const schema_dir_env = 'ARXMODEL_SCHEMA_DIR'

// config_path is the user's configuration file: $XDG_CONFIG_HOME/arxmodel/config.toml, else
// ~/.config/arxmodel/config.toml.
pub fn config_path() string {
	base := os.getenv('XDG_CONFIG_HOME')
	dir := if base != '' { base } else { os.join_path(os.home_dir(), '.config') }
	return os.join_path(dir, 'arxmodel', 'config.toml')
}

// parse_config reads a configuration: `schema_dir = "DIR"`, nothing else; a relative directory is
// read from the file's own directory.
pub fn parse_config(text string, path string) !string {
	doc := toml.parse_text(text) or { return error('${path}: ${err.msg()}') }
	mut dir := ''
	for k, v in doc.to_any().as_map() {
		if k != 'schema_dir' {
			return error('${path}: unknown setting `${k}`')
		}
		if v !is string || v.string() == '' {
			return error('${path}: `schema_dir` takes a directory')
		}
		dir = v.string()
	}
	if dir != '' && !os.is_abs_path(dir) {
		dir = os.join_path(os.dir(path), dir)
	}
	return dir
}

// configured_schema_dir is the schema directory this machine names, and where it is named: the
// environment variable first, then the configuration file; '' when neither names one.
pub fn configured_schema_dir() !(string, string) {
	if env := os.getenv_opt(schema_dir_env) {
		if env != '' {
			return env, schema_dir_env
		}
	}
	path := config_path()
	// none configured where the file is not there; one that cannot be reached or read is an
	// error, never a quiet fall back to other merge rules
	os.stat(path) or {
		if err.code() == enoent {
			return '', ''
		}
		return error('${path}: ${err.msg()}')
	}
	text := os.read_file(path) or { return error('${path}: ${err.msg()}') }
	dir := parse_config(text, path)!
	return dir, path
}
