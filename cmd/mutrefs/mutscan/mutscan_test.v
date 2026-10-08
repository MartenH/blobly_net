module mutscan

fn lines(src string) []int {
	found := scan_text(src, 'fixture.v') or { panic(err) }
	return found.map(it.line)
}

// the shape of the #402 crash: diag_attach bound a copy of the App
fn test_bind_address_of_receiver() {
	assert lines('module main
fn (mut app App) diag_attach() {
	ap := &app
	register(fn [ap] () {})
}
') == [3]
	assert lines('module main
fn (mut app App) f() {
	mut ap := &app
	x, y := 1, &app
}
') == [3, 4]
}

fn test_closure_captures_receiver_by_value() {
	found := scan_text('module main
fn (mut app App) f() {
	register(fn [app] () {})
}
', 'fixture.v') or { panic(err) }
	assert found.len == 1
	assert found[0].str() == 'fixture.v:3: closure captures app by value, a copy of the mut receiver (bind a := app first, or capture mut app)'
}

fn test_reference_and_mut_capture_are_allowed() {
	assert lines('module main
fn (mut app App) f() {
	a := app
	p := &app.field
	q := voidptr(&app)
	register(fn [mut app] () {})
	register(fn [a] () {})
}
') == []
}

// #406 edge 1: a `//` inside a string must not hide the capture after it
fn test_slashes_in_a_string_hide_nothing() {
	assert lines("module main
fn (mut app App) f() {
	register('http://x', fn [app] () {})
}
") == [3]
}

// #406 edge 2: a comparison with &app is not a binding
fn test_comparison_is_not_a_binding() {
	assert lines('module main
fn (mut app App) f(candidate &App) {
	same := candidate == &app
	ok := &app == candidate
}
') == []
}

// #406 edge 3: a one-line method body is still a method body
fn test_one_line_method() {
	assert lines('module main
fn (mut app App) f() { register(fn [app] () {}) }
') == [2]
}

fn test_patterns_in_comments_and_strings_are_not_code() {
	assert lines("module main
fn (mut app App) f() {
	// ap := &app and fn [app] () {}
	/* ap := &app
	   register(fn [app] () {}) */
	s := 'ap := &app; fn [app] () {}'
	t := 'fn [\${app.name}] ap := &app'
}
") == []
}

fn test_multi_line_capture_list() {
	assert lines('module main
fn (mut app App) f() {
	x, y := 1, 2
	register(fn [
		x,
		app,
		mut y
	] () {})
}
') == [6]
}

// a closure or binding hidden where the AST walker does not look on its own
fn test_nested_and_spawned_closures() {
	assert lines('module main
fn (mut app App) f() {
	spawn fn [app] () {}()
	go fn [app] () {}()
	for i := 0; i < run(fn [app] () {}); i++ {}
	if x := pick(fn [app] () {}) {
		register(fn [mut app] () {
			register(fn [app] () {})
		})
	}
}
') == [3, 4, 5, 6, 8]
}

fn test_only_mut_receivers_are_asked() {
	assert lines('module main
fn (app App) f() {
	ap := &app
	register(fn [app] () {})
}
fn (app &App) g() {
	register(fn [app] () {})
}
fn h(mut app App) {
	register(fn [app] () {})
}
') == []
}

fn test_receiver_name_is_the_method_own() {
	assert lines('module main
fn (mut s Server) f() {
	app := s
	register(fn [app] () {})
	p := &s
}
') == [5]
}

fn test_a_parse_error_is_an_error_not_a_pass() {
	if _ := scan_text('module main
fn (mut app App) f( {
', 'broken.v') {
		assert false, 'a file the parser refuses must not read as clean'
	}
}

fn test_parent_receiver_spellings_that_do_not_copy() {
	// measured on the pinned compiler: neither reads a stale value after `app.x = 7`
	assert lines('module main
fn (mut app App) f() {
	mut e := &App{}
	e = &app
	d := (&app)
	m := mask & app.flags
	p := &app.items[0]
}
') == []
}

// a top-level `$if` holds methods too
fn test_method_inside_comptime_if() {
	assert lines('module main
\$if linux {
	fn (mut app App) g() {
		ap := &app
	}
}
') == [4]
}

// `or { }` on an index, a selector or an ident is where a callback is often registered
fn test_closure_in_an_or_block() {
	assert lines("module main
fn (mut app App) f(m map[string]int) {
	x := m['a'] or { register(fn [app] () {}); 0 }
	y := app.opt or { register(fn [app] () {}); 0 }
}
") == [3, 4]
}

fn test_two_findings_on_one_line_are_two() {
	assert lines('module main
fn (mut app App) f() {
	register(fn [app] () {}, fn [app] () {})
	a, b := &app, &app
}
') == [3, 3, 4, 4]
}

// a spelling the walk never judged is an error of the tool, never a pass
fn test_census_refuses_what_the_walk_did_not_reach() {
	src := 'module main
fn (mut app App) f() {
	ap := &app
	register(fn [app] () {})
}
'
	start := src.index('{') or { 0 }
	unjudged := &Scan{
		file:    'fixture.v'
		methods: [Method{'app', start, src.len}]
	}
	census(src, 'fixture.v', unjudged, new_prefs()) or {
		assert err.msg() == 'fixture.v:3: mutrefs did not reach `&app` here; its walk is missing a node kind'
		return
	}
	assert false, 'the census passed a file nobody walked'
}
