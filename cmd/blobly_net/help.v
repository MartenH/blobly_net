module main

import os
import strings
import markdown

// help_docs lists the Help pages: the built-in quick start (empty path) plus real markdown docs
// loaded from disk. Paths are resolved relative to the working dir (the app chdir's to its
// bundle dir at startup, so these resolve in a distributed build too).
struct HelpDoc {
	title string
	path  string // '' = built-in quick_ref_md
}

const help_docs = [
	HelpDoc{'Quick start', ''},
	HelpDoc{'Simulation', 'docs/simulation.md'},
	HelpDoc{'Scripting', 'docs/scripting.md'},
	HelpDoc{'Project editing', 'docs/project_editing.md'},
	HelpDoc{'CAN hardware', 'docs/can_hardware.md'},
	HelpDoc{'Ethernet / DoIP', 'docs/doip.md'},
	HelpDoc{'Known issues', 'docs/known_issues.md'},
]

const quick_ref_md = '# Blobly Net

An imgui/ImPlot CAN/automotive bus tester. **Start/Stop** runs the measurement on the
enabled channels; the activity bar (far left) and the **View** menu toggle panels; **Settings**
sets the frame rate and UI scale.

## Panels

- **Buses** — channel enable and live state
- **Cfg / Configuration** — edit the project: buses in a form, or the `.blobnet` as text
- **Simulation** — in-process simulated ECUs (driver-free)
- **Symbols** — DBC message / signal browser (searchable)
- **Trace / Trace (filter)** — live frames, all or grouped, filterable, per-bus
- **Signals** — decode the selected message; add signals to Graphics
- **Graphics** — live ImPlot signal plots (multi-axis, real values)
- **Trace Chart** — telemetry handler swimlane
- **Shell** — command line on the target (over CAN; Up/Down = history)
- **Generators** — quick send + saved senders (manual / on-key / cyclic)
- **Diagnostics / DoIP** — UDS diagnostics and DoIP discovery
- **Script** — run a Lua test file

## Trace capture controls

In the **Trace** window: **Pause** freezes what every view takes in, **Clear** empties the
capture (counters included), **Record** writes the frames to a timestamped
`recording-YYYYMMDD-HHmmss.log` beside the open project — each capture gets its own file, and
the destination is shown next to the button while recording. While a recording or a pause is
active, the toolbar shows a chip with the matching control, so neither state can get stranded
behind a closed window.

**File ▸ Open Recording (.log/.mf4)** loads a capture into the trace for inspection (rows
marked `REP`); the capture pauses while a file is shown, and **resume live** hands the view
back without clearing anything. The shipped demo lives in `samples/` — the picker has a button
for it.

## Generators

A generator is a reusable send block. Give it a single **key** and set its trigger to
**on key** to fire it from the keyboard while running. **cyclic** auto-repeats at its period.
Use **Quick send** at the top for an ad-hoc one-shot without saving a generator.
'

// help_style + help_script are the Help page CSS/JS. Raw strings (single-quote delimited) so the
// double quotes inside are literal; kept free of single quotes so they never terminate the string.
const help_style = r'
*{box-sizing:border-box}
body{margin:0;font-family:-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;line-height:1.6;color:#1b1b1b;background:#fff}
#wrap{display:flex;min-height:100vh}
nav{width:250px;flex:none;border-right:1px solid #e2e2e2;padding:1rem;height:100vh;position:sticky;top:0;overflow:auto}
nav h2{font-size:1rem;margin:.2rem 0 .8rem}
#q{width:100%;padding:.5em .6em;border:1px solid #ccc;border-radius:6px;font-size:.95em;margin-bottom:.8rem}
ul#nav{list-style:none;margin:0;padding:0}
.navitem{padding:.4em .6em;border-radius:6px;cursor:pointer;font-size:.95em}
.navitem:hover{background:#f0f0f0}
.xref{color:#0078d4;cursor:pointer;text-decoration:underline}
.navitem.active{background:#0078d4;color:#fff}
#results{margin-top:.6rem}
.result{padding:.5em .6em;border-radius:6px;cursor:pointer;font-size:.82em;border:1px solid #eee;margin-bottom:.4rem}
.result:hover{background:#f5f5f5}
.result .rp{font-weight:600;color:#0078d4;margin-bottom:.2em}
main{flex:1;max-width:900px;padding:1.5rem 2.5rem;overflow:auto}
.page.hidden{display:none}
h1,h2,h3{line-height:1.25;margin-top:1.5em}
h1{border-bottom:2px solid #0078d4;padding-bottom:.2em;margin-top:.2em}
h2{border-bottom:1px solid #ddd;padding-bottom:.2em}
code{background:#f3f3f3;padding:.1em .35em;border-radius:3px;font-size:.92em}
pre{background:#f6f8fa;padding:1em;border-radius:6px;overflow:auto}
pre code{background:none;padding:0}
a{color:#0078d4}
hr{border:0;border-top:1px solid #ddd;margin:2.5em 0}
table{border-collapse:collapse}td,th{border:1px solid #ddd;padding:.4em .6em}
mark{background:#ffe066;color:inherit;border-radius:2px}
@media(prefers-color-scheme:dark){
body{color:#d4d4d4;background:#1e1e1e}
nav{border-color:#333}
#q{background:#2d2d2d;border-color:#444;color:#d4d4d4}
.navitem:hover{background:#2a2a2a}
.result{border-color:#333}.result:hover{background:#2a2a2a}
code{background:#2d2d2d}pre{background:#252526}
h2,hr,td,th{border-color:#3a3a3a}a{color:#4ea1ff}
mark{background:#7a5c00;color:#fff}
}
'

const help_script = r'
(function(){
var pages=[].slice.call(document.querySelectorAll(".page"));
var navitems=[].slice.call(document.querySelectorAll(".navitem"));
var results=document.getElementById("results");
var q=document.getElementById("q");
var content=document.getElementById("content");
function show(idx){
pages.forEach(function(p,i){p.classList.toggle("hidden",i!==idx);});
navitems.forEach(function(n,i){n.classList.toggle("active",i===idx);});
}
document.addEventListener("click",function(e){var x=e.target.closest?e.target.closest("[data-goto]"):null;if(!x)return;e.preventDefault();clearMarks();results.textContent="";q.value="";show(parseInt(x.getAttribute("data-goto")));content.scrollTop=0;});
navitems.forEach(function(n){n.addEventListener("click",function(){clearMarks();results.textContent="";q.value="";show(parseInt(n.getAttribute("data-page")));content.scrollTop=0;});});
function clearMarks(){var ms=[].slice.call(document.querySelectorAll("mark"));ms.forEach(function(m){var t=document.createTextNode(m.textContent);var par=m.parentNode;par.replaceChild(t,m);par.normalize();});}
function highlight(el,term){var first=null;var low=term.toLowerCase();var nodes=[];var w=document.createTreeWalker(el,NodeFilter.SHOW_TEXT,null);while(w.nextNode())nodes.push(w.currentNode);nodes.forEach(function(node){var txt=node.nodeValue;var lo=txt.toLowerCase();var idx=lo.indexOf(low);if(idx<0)return;var frag=document.createDocumentFragment();var pos=0;while(idx>=0){frag.appendChild(document.createTextNode(txt.slice(pos,idx)));var m=document.createElement("mark");m.textContent=txt.slice(idx,idx+term.length);frag.appendChild(m);if(!first)first=m;pos=idx+term.length;idx=lo.indexOf(low,pos);}frag.appendChild(document.createTextNode(txt.slice(pos)));node.parentNode.replaceChild(frag,node);});return first;}
function search(term){clearMarks();results.textContent="";if(!term){return;}var low=term.toLowerCase();var any=false;pages.forEach(function(p,i){var txt=p.textContent;var lo=txt.toLowerCase();var idx=lo.indexOf(low);if(idx<0)return;any=true;var c=0,k=idx;while(k>=0){c++;k=lo.indexOf(low,k+term.length);}var st=Math.max(0,idx-30);var snip=(st>0?"…":"")+txt.slice(st,idx+term.length+50).replace(/\s+/g," ").trim()+"…";var div=document.createElement("div");div.className="result";var rp=document.createElement("div");rp.className="rp";rp.textContent=navitems[i].textContent+" ("+c+")";div.appendChild(rp);div.appendChild(document.createTextNode(snip));div.addEventListener("click",function(){results.textContent="";show(i);var m=highlight(p,term);content.scrollTop=0;if(m)m.scrollIntoView({block:"center"});});results.appendChild(div);});if(!any){var d=document.createElement("div");d.className="result";d.textContent="No matches";results.appendChild(d);}}
q.addEventListener("input",function(){search(q.value.trim());});
})();
'

// help_text returns a Help doc body, reading + caching the file on first access.
fn (mut app App) help_text(path string) string {
	if path == '' {
		return quick_ref_md
	}
	if path in app.help_cache {
		return app.help_cache[path]
	}
	txt := os.read_file(path) or { 'Could not load `${path}`.\n\nIt may not ship in this build.' }
	app.help_cache[path] = txt
	return txt
}

// rewrite_help_links makes relative `*.md` links usable inside the single-file Help page.
//
// Help renders every page into ONE html file written to a cache directory, so a link like
// `scripting.md` resolves beside that cached file and opens nothing. Three shipped pages
// already carried such links before the Simulation manual added more.
//
//   - target IS a Help page  -> an in-page jump (`data-goto`), handled by the nav script
//   - target is NOT          -> the link is dropped and its text kept, because a dead link
//                               that looks live is worse than plain text
fn rewrite_help_links(html string) string {
	mut base_to_idx := map[string]int{}
	for i, d in help_docs {
		if d.path != '' {
			base_to_idx[d.path.all_after_last('/')] = i
		}
	}
	mut out := html
	for _ in 0 .. 64 { // bounded: each pass rewrites one link, and pages have few
		start := out.index('<a href="') or { break }
		qs := start + '<a href="'.len
		qe := out.index_after('"', qs) or { break }
		href := out[qs..qe]
		gt := out.index_after('>', qe) or { break }
		close := out.index_after('</a>', gt) or { break }
		text := out[gt + 1..close]
		mut repl := ''
		if href.ends_with('.md') && !href.starts_with('http') {
			if idx := base_to_idx[href.all_after_last('/')] {
				repl = '<span class="xref" data-goto="${idx}">${text}</span>'
			} else {
				repl = text // not a Help page: keep the words, drop the dead link
			}
		} else {
			// leave it alone, but mark it so the scan moves past it
			repl = '<a data-ok href="${href}"' + out[qe + 1..close] + '</a>'
		}
		out = out[..start] + repl + out[close + '</a>'.len..]
	}
	return out.replace('<a data-ok ', '<a ')
}

// help_html renders the Help docs into ONE self-contained, static HTML page: a sidebar of pages,
// full-text search across them, and each doc rendered via vlang/markdown (headings, code, tables).
// Pure client-side JS — no web server. Written once, opened as a file:// URL.
fn (mut app App) help_html() string {
	mut nav := strings.new_builder(1024)
	mut pages := strings.new_builder(65536)
	for i, d in help_docs {
		active := if i == 0 { ' active' } else { '' }
		hidden := if i == 0 { '' } else { ' hidden' }
		nav.write_string('<li class="navitem${active}" data-page="${i}">${d.title}</li>')
		body := rewrite_help_links(markdown.to_html(app.help_text(d.path)))
		pages.write_string('<div class="page${hidden}" id="page-${i}">${body}</div>')
	}
	return '<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8">' +
		'<meta name="viewport" content="width=device-width, initial-scale=1">' +
		'<title>Blobly Net — Help</title><style>${help_style}</style></head><body>' +
		'<div id="wrap"><nav><h2>Blobly Net Help</h2>' +
		'<input id="q" type="search" placeholder="Search all pages…" autocomplete="off">' +
		'<ul id="nav">${nav.str()}</ul><div id="results"></div></nav>' +
		'<main id="content">${pages.str()}</main></div>' +
		'<script>${help_script}</script></body></html>\n'
}

// open_help_in_browser writes the rendered Help HTML to a per-user cache file and opens it in the
// system browser (imgui is effectively one desktop app; the browser is the nicely-rendered view).
fn (mut app App) open_help_in_browser() {
	app.notify('opening Help in browser')
	dir := os.join_path(os.cache_dir(), 'blobly_net')
	os.mkdir_all(dir) or {}
	os.chmod(dir, 0o700) or {} // not a shared /tmp — avoid a symlink pre-plant
	path := os.join_path(dir, 'help.html')
	os.write_file(path, app.help_html()) or {
		app.notify('Help: could not write ${path} (${err})')
		return
	}
	ok, note := open_uri_in_browser(path)
	app.notify(if ok { note } else { 'Help written to ${path} — ${note}' })
}

// is_wsl reports whether we're under WSL, where os.open_uri finds no Linux browser.
fn is_wsl() bool {
	if os.getenv('WSL_DISTRO_NAME') != '' || os.getenv('WSL_INTEROP') != '' {
		return true
	}
	rel := os.read_file('/proc/sys/kernel/osrelease') or { return false }
	low := rel.to_lower()
	return low.contains('microsoft') || low.contains('wsl')
}

// open_uri_in_browser opens `path` in the system browser. Under WSL, os.open_uri finds no Linux
// browser, so route to the Windows browser via wslview (wslu) or explorer.exe with a wslpath UNC.
fn open_uri_in_browser(path string) (bool, string) {
	if is_wsl() {
		if exe := os.find_abs_path_of_executable('wslview') {
			mut p := os.new_process(exe)
			p.set_args([path])
			p.run()
			p.wait()
			if p.code == 0 {
				return true, 'opened Help in the Windows browser'
			}
		}
		if exe := os.find_abs_path_of_executable('explorer.exe') {
			win := os.execute('wslpath -w ' + os.quoted_path(path))
			if win.exit_code == 0 {
				mut p := os.new_process(exe)
				p.set_args([win.output.trim_space()])
				p.run()
				p.wait()
				return true, 'opening Help in the Windows browser'
			}
		}
		return false, 'open it manually (install wslu for wslview)'
	}
	os.open_uri(path) or { return false, 'open it manually (${err.msg()})' }
	return true, 'opened Help in browser'
}
