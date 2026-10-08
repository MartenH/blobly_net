// mutscan finds the two V spellings that COPY a `mut` receiver (docs/known_issues.md), by asking
// V's own parser rather than matching text: inside `fn (mut app App) f()`, `ap := &app` binds a
// copy of the struct, and so does a closure capturing it by value, `fn [app] () {}`. `a := app`,
// `(&app)`, `e = &app` into an existing reference, and `fn [mut app]` do not copy (measured on the
// pinned compiler). Strings, comments, comparisons and one-line bodies are the parser's to tell
// apart, which is why this is an AST walk and not a regex (#406).
//
// The walk is held to a census: every `&<recv>` and every `fn [` token in a mut-receiver method,
// read by V's own scanner, must be a node the walk judged. V's `walker` does not visit every
// field of every node, so a spelling in a field it skips is reported as an error of this tool
// rather than passing in silence.
module mutscan

import os
import v.ast
import v.ast.walker
import v.parser
import v.pref
import v.scanner
import v.token

pub struct Finding {
pub:
	file string
	line int // 1-based
	msg  string
	at   int // byte offset, for a stable order within a line
}

pub fn (f Finding) str() string {
	return '${f.file}:${f.line}: ${f.msg}'
}

// scan_file parses one V source file and reports every copied mut receiver in it.
pub fn scan_file(path string) ![]Finding {
	text := os.read_file(path)!
	return scan_text(text, path)
}

// scan_text is scan_file over source held in memory; `path` only names it in the findings. An
// error is a file the parser refuses, or a spelling the walk did not reach.
pub fn scan_text(text string, path string) ![]Finding {
	prefs := new_prefs()
	mut table := ast.new_table()
	file := parser.parse_text(text, path, mut table, .skip_comments, prefs)
	if file.errors.len > 0 {
		e := file.errors[0]
		return error('${path}:${e.pos.line_nr + 1}: parse error: ${e.message}')
	}
	mut v := &Scan{
		file: path
	}
	walker.walk(mut v, &ast.Node(ast.File(*file)))
	// what the walker's children() leaves out, queued by visit with its receiver and walked here
	for v.pending.len > 0 {
		p := v.pending.pop()
		v.recv = p.recv
		walker.walk(mut v, &p.node)
	}
	census(text, path, v, prefs)!
	mut out := v.found.clone()
	out.sort_with_compare(fn (a &Finding, b &Finding) int {
		return a.at - b.at
	})
	return out
}

fn new_prefs() &pref.Preferences {
	mut p := pref.new_preferences()
	p.enable_globals = true // modules/transport/inproc.v uses __global
	p.output_mode = .silent
	return p
}

struct Method {
	recv  string
	start int // the body's `{`
	end   int // the token after its `}`
}

struct Pending {
	node ast.Node
	recv string
}

struct Scan {
	file string
mut:
	recv    string // the mut receiver of the method being walked, '' outside one
	methods []Method
	found   []Finding
	pending []Pending
	amps    map[int]bool // offsets of every `&` operator the walk reached
	fns     map[int]bool // offsets of every closure the walk judged
}

fn (mut v Scan) visit(node &ast.Node) ! {
	if node is ast.Stmt {
		match node {
			ast.FnDecl {
				// a named fn is top level (or in a top-level $if), so this is the one being
				// entered; an anonymous fn's decl keeps the enclosing receiver
				if !node.is_anon {
					v.recv = if node.is_method && node.rec_mut { node.receiver.name } else { '' }
					if v.recv != '' {
						v.methods << Method{v.recv, node.body_pos.pos, node.end_pos.pos}
					}
				}
			}
			ast.AssignStmt {
				// only a bare `x := &recv` copies: `(&recv)` and `x = &recv` do not
				if node.op == .decl_assign {
					for r in node.right {
						if r is ast.PrefixExpr && r.op == .amp && is_ident(r.right, v.recv) {
							v.say(r.pos, 'binds &${v.recv}, a copy of the mut receiver')
						}
					}
				}
			}
			ast.AssertStmt {
				v.queue(node.extra)
			}
			ast.ForStmt {
				v.queue(node.cond)
			}
			ast.ForInStmt {
				v.queue(node.cond)
				v.queue(node.high)
			}
			ast.ForCStmt {
				v.queue(node.init)
				v.queue(node.cond)
				v.queue(node.inc)
			}
			else {}
		}
		return
	}
	if node !is ast.Expr {
		return
	}
	expr := node as ast.Expr
	match expr {
		ast.PrefixExpr {
			if expr.op == .amp {
				v.amps[expr.pos.pos] = true
			}
			v.queue(ast.Expr(expr.or_block))
		}
		ast.InfixExpr {
			if expr.op == .amp {
				v.amps[expr.pos.pos] = true // `mask & app.flags`, which the census also sees
			}
			v.queue(ast.Expr(expr.or_block)) // `ch <- x or { }`
		}
		ast.AnonFn {
			if expr.decl.pos.pos !in v.fns {
				v.fns[expr.decl.pos.pos] = true
				for p in expr.inherited_vars {
					if is_ident_name(p.name, v.recv) && !p.is_mut && !p.is_shared {
						v.say(p.pos, 'closure captures ${v.recv} by value, a copy of the mut receiver (bind a := ${v.recv} first, or capture mut ${v.recv})')
					}
				}
			}
		}
		ast.GoExpr {
			v.queue(ast.Expr(expr.call_expr))
		}
		ast.SpawnExpr {
			v.queue(ast.Expr(expr.call_expr))
		}
		ast.IfExpr {
			for b in expr.branches {
				v.queue(b.cond)
			}
		}
		ast.ArrayInit {
			v.queue(expr.len_expr)
			v.queue(expr.cap_expr)
			v.queue(expr.init_expr)
		}
		ast.StructInit {
			v.queue(expr.update_expr)
		}
		ast.ComptimeCall {
			for a in expr.args {
				v.queue(a.expr)
			}
			v.queue(ast.Expr(expr.or_block))
		}
		ast.IsRefType {
			v.queue(expr.expr)
		}
		ast.DumpExpr {
			v.queue(expr.expr)
		}
		ast.LockExpr {
			for l in expr.lockeds {
				v.queue(l)
			}
		}
		// `or { }` on an index, a selector or an ident: children() walks only a call's
		ast.IndexExpr {
			v.queue(ast.Expr(expr.or_expr))
		}
		ast.SelectorExpr {
			v.queue(ast.Expr(expr.or_block))
		}
		ast.Ident {
			v.queue(ast.Expr(expr.or_expr))
		}
		else {}
	}
}

fn (mut v Scan) queue(n ast.Node) {
	v.pending << Pending{n, v.recv}
}

fn (mut v Scan) say(pos token.Pos, msg string) {
	v.found << Finding{
		file: v.file
		line: pos.line_nr + 1
		msg:  msg
		at:   pos.pos
	}
}

fn is_ident(e ast.Expr, recv string) bool {
	return e is ast.Ident && is_ident_name(e.name, recv)
}

fn is_ident_name(name string, recv string) bool {
	return recv != '' && name == recv
}

// census (a Token line_nr is 1-based, a Pos one 0-based): every `&<recv>` and `fn [` token inside a mut-receiver method must have been judged
fn census(text string, path string, v &Scan, prefs &pref.Preferences) ! {
	if v.methods.len == 0 {
		return
	}
	mut s := scanner.new_scanner(text, .skip_comments, prefs)
	mut prev := s.scan()
	for prev.kind != .eof {
		tok := s.scan()
		for m in v.methods {
			if prev.pos < m.start || prev.pos >= m.end {
				continue
			}
			if prev.kind == .amp && tok.kind == .name && tok.lit == m.recv && prev.pos !in v.amps {
				return error('${path}:${prev.line_nr}: mutrefs did not reach `&${m.recv}` here; its walk is missing a node kind')
			}
			if prev.kind == .key_fn && tok.kind == .lsbr && prev.pos !in v.fns {
				return error('${path}:${prev.line_nr}: mutrefs did not reach this closure; its walk is missing a node kind')
			}
		}
		prev = tok
	}
}
