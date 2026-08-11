// vgui — a small V binding for Dear ImGui + ImPlot (docking / multi-viewport, GLFW/GL3).
// Clean V API over a curated scalar C ABI (vgui_glue.cpp) sitting on cimgui/cimplot — the
// same wrap-C-in-a-facade pattern blobly_net uses for Lua/SocketCAN, so the V<->C surface
// stays small and stable (unlike a raw ~800-fn cimgui binding). Reusable across projects.
module vgui

#flag -I@VMODROOT
// Link the prebuilt C++ archive. LINUX keeps the validated positional path. WINDOWS must pass
// it as a LINKER input (-l:), NOT a positional file: on Windows V compiles+links in ONE
// `-x c <src>` command, and a bare `@VMODROOT/libvgui_c.a` path is then swept up by the sticky
// `-x c` → gcc tries to *compile the archive as C* → a multi-GB "stray byte" error storm that
// overflows V's output capture and surfaces as a V panic
// (`array.push_many: new len exceeds max_int` in os__windows_execute_command_line). `-l:` is a
// linker option, immune to `-x c`. (Linux links separately, so the positional path is fine there.)
#flag linux @VMODROOT/libvgui_c.a
#flag windows -L@VMODROOT
#flag windows -l:libvgui_c.a
// Linux/WSL: GLFW (X11) + GL + the C++ runtime the imgui/implot objects need.
#flag linux -lglfw -lGL -lstdc++ -ldl -lm -lfreetype
// Windows (mingw): link GLFW3 *statically* (-l:libglfw3.a, so no glfw3.dll/winpthread
// to ship) + its Win32 deps (gdi32/imm32/shell32/user32) + opengl32; -lstdc++ for the
// imgui/implot C++ objects, static libstdc++/libgcc so the exe carries no MinGW runtime
// DLLs (deps end up: kernel32/user32/gdi32/shell32/opengl32/msvcrt only). Multi-viewport
// is native Win32 (no X11). Verified: mingw-w64 gcc 16.1.0, self-contained exe, GL 4.6.
// FreeType (crisp text): needs `pacman -S mingw-w64-x86_64-freetype`. mingw's libfreetype.a
// is built WITH HarfBuzz, so a *static* link drags in the full transitive chain — the libs
// below are `pkg-config --static --libs freetype2` verbatim (harfbuzz→glib/dwrite/usp10/
// pcre2/intl/graphite2, png→z, brotli, bz2). HarfBuzz + graphite2 are C++, so `-lstdc++`
// MUST come LAST (after them) or you get `undefined reference to __cxa_*`. If your toolchain
// differs, regenerate the middle chain with `pkg-config --static --libs freetype2`.
// -mwindows: link as a GUI-subsystem exe so Windows does NOT spawn a console window
// alongside the app (mingw defaults to the console subsystem; the old MSVC build used the
// equivalent /SUBSYSTEM:WINDOWS). V's main() is still the entry point (that's -municode, not
// -mwindows). startup prints just have no console to land in — fine for a shipped GUI app.
#flag windows -mwindows -static -l:libglfw3.a -lopengl32 -lgdi32 -limm32 -lshell32 -luser32 -static-libstdc++ -static-libgcc -lfreetype -lbz2 -lpng16 -lz -lharfbuzz -lusp10 -ldwrite -lglib-2.0 -lintl -lole32 -lwinmm -lshlwapi -luuid -latomic -lpcre2-8 -lgraphite2 -lbrotlidec -lbrotlicommon -lrpcrt4 -lws2_32 -ladvapi32 -lstdc++ -l:libgdi32.a
#include "vgui.h"

// Bar mirrors the C `VBar` (SoA-free struct passed by pointer; C-compatible layout).
pub struct Bar {
pub:
	t0        f32 // start, µs (relative to capture start)
	dur       f32 // cpu_us
	lane      int
	color     u32 // packed IM_COL32 (RGBA, little-endian ABGR in memory)
	warn      int // overran/saturated -> red outline
	preempted int // torn-edge mark at the slice's end (an involuntary cut)
	style     int // 0 = running; 1 = ready-but-waiting (thin + dim)
}

// Link is one preemption cut: a vertical connector at time x from the victim's lane to the
// preemptor's lane (the dot end).
pub struct Link {
pub mut:
	x         f32
	lane_from int
	lane_to   int
}

fn C.vgui_init(&char, int, int, int) int
fn C.vgui_set_window_icon(int, int, &u8)
fn C.vgui_plot_begin_x(&char, f32, f64, f64) int
fn C.vgui_is_item_clicked_right() int
fn C.vgui_running() int
fn C.vgui_frame_begin()
fn C.vgui_dockspace()
fn C.vgui_frame_end()
fn C.vgui_shutdown()
fn C.vgui_time() f64
fn C.vgui_wake()
fn C.vgui_add_font(&char, f32) int
fn C.vgui_set_theme(int)
fn C.vgui_set_font_scale(f32)
fn C.vgui_dump_ppm(&char)
fn C.vgui_swimlane(&char, int, &&char, voidptr, int, voidptr, int, f32, &f64, &f64)
fn C.vgui_set_next_window(f32, f32, f32, f32)
fn C.vgui_set_window_focus(&char)
fn C.vgui_indent_x(f32)
fn C.vgui_indent_y(f32)
fn C.vgui_push_frame_padding(f32, f32)
fn C.vgui_push_window_padding(f32, f32)
fn C.vgui_pop_style_var(int)
fn C.vgui_activity_style_push()
fn C.vgui_activity_style_pop()
fn C.vgui_dock_2col(&char, &char, f32)
fn C.vgui_dock_3(&char, &char, &char, f32, f32)
fn C.vgui_menu_bar_begin() int
fn C.vgui_menu_bar_end()
fn C.vgui_menu_begin(&char) int
fn C.vgui_menu_end()
fn C.vgui_menu_item(&char) int
fn C.vgui_begin_popup_context_item(&char) int
fn C.vgui_begin_popup_context_window() int
fn C.vgui_clipboard_set(&char)
fn C.vgui_end_popup()
fn C.vgui_menu_item_check(&char, int) int
fn C.vgui_checkbox(&char, int) int
fn C.vgui_text_colored(int, int, int, &char)
fn C.vgui_small_button(&char) int
fn C.vgui_spacing()
fn C.vgui_separator()
fn C.vgui_quit()
fn C.vgui_plot_begin(&char, f32) int
fn C.vgui_plot_line(&char, &f32, &f32, int)
fn C.vgui_plot_begin2(&char, f32, f64, f64, int) int
fn C.vgui_plot_line_axis(&char, &f32, &f32, int, int)
fn C.vgui_plot_is_hovered() int
fn C.vgui_plot_mouse_x() f64
fn C.vgui_plot_end()
fn C.vgui_selectable(&char, int) int
fn C.vgui_child_begin(&char, f32)
fn C.vgui_child_fill(&char)
fn C.vgui_toggle_button(&char, int, f32) int
fn C.vgui_child_wh(&char, f32, f32)
fn C.vgui_child_end()
fn C.vgui_input_text(&char, &char, int) int
fn C.vgui_console_input(&char, &char, int) int
fn C.vgui_scroll_bottom()
fn C.vgui_console_text(&char, &char, int, int)
fn C.vgui_text_edit(&char, &char, int, f32) int
fn C.vgui_input_double(&char, &f64) int
fn C.vgui_input_int(&char, &int) int
fn C.vgui_set_next_item_width(f32)
fn C.vgui_tree_node(&char) int
fn C.vgui_tree_node_open(&char) int
fn C.vgui_tree_pop()
fn C.vgui_dock_root() u32
fn C.vgui_dock_split(u32, int, f32, &u32) u32
fn C.vgui_dock_window(&char, u32)
fn C.vgui_dock_finish(u32)
fn C.vgui_begin(&char) int
fn C.vgui_begin_closable(&char, &int) int
fn C.vgui_set_item_tooltip(&char)
fn C.vgui_help_marker(&char)
fn C.vgui_end()
fn C.vgui_text(&char)
fn C.vgui_text_dim(&char)
fn C.vgui_button(&char) int
fn C.vgui_button_big(&char, int, int, int, f32, f32) int
fn C.vgui_splitter_v(&char, f32, f32, f32) f32
fn C.vgui_content_avail_w() f32
fn C.vgui_is_item_deactivated_after_edit() int
fn C.vgui_same_line()
fn C.vgui_separator_text(&char)
fn C.vgui_table_begin(&char, int) int
fn C.vgui_table_col(&char)
fn C.vgui_table_headers()
fn C.vgui_table_row()
fn C.vgui_table_cell(&char)
fn C.vgui_table_next_col()
fn C.vgui_tree_node_table(&char) int
fn C.vgui_is_item_clicked() int
fn C.vgui_table_setup_col(&char, f32)
fn C.vgui_table_freeze_top()
fn C.vgui_table_end()
fn C.vgui_fps() f32
fn C.vgui_want_text_input() int
fn C.vgui_key_pressed(int) int
fn C.vgui_combo(&char, &&char, int, int) int

// --- lifecycle ---
pub fn init(title string, w int, h int, event_driven bool) bool {
	return C.vgui_init(title.str, w, h, if event_driven { 1 } else { 0 }) == 0
}

// set_window_icon sets the OS window / taskbar icon from a w×h RGBA8 buffer (row-major,
// top-left origin, 4 bytes/pixel). Call after init(). `rgba.len` must be w*h*4.
pub fn set_window_icon(w int, h int, rgba []u8) {
	if rgba.len < w * h * 4 {
		return
	}
	C.vgui_set_window_icon(w, h, &u8(rgba.data))
}

pub fn running() bool {
	return C.vgui_running() == 1
}

pub fn frame_begin() {
	C.vgui_frame_begin()
}

// dockspace fills the host window's remaining region with the dockspace (call it after the
// menu bar + activity bar, before build_layout / panels).
pub fn dockspace() {
	C.vgui_dockspace()
}

pub fn frame_end() {
	C.vgui_frame_end()
}

pub fn shutdown() {
	C.vgui_shutdown()
}

// wake requests a repaint from another thread (unblocks the event-driven loop). Thread-safe.
pub fn wake() {
	C.vgui_wake()
}

// add_font loads a TTF as the UI font (call after init(), before the first frame). Returns
// true on success. imgui asserts on a bad path, so the caller must verify the file exists.
pub fn add_font(path string, size f32) bool {
	return C.vgui_add_font(path.str, size) == 1
}

// set_theme switches the palette (true = dark, false = light) and re-applies the style.
pub fn set_theme(dark bool) {
	C.vgui_set_theme(if dark { 1 } else { 0 })
}

// set_font_scale scales all UI text (1.0 = native). Cheap zoom.
pub fn set_font_scale(s f32) {
	C.vgui_set_font_scale(s)
}

pub fn time() f64 {
	return C.vgui_time()
}

pub fn dump_ppm(path string) {
	C.vgui_dump_ppm(path.str)
}

pub fn fps() f32 {
	return C.vgui_fps()
}

// want_text_input is true while a text field is focused (imgui owns the keyboard) — check it
// before acting on single-key shortcuts so typing doesn't trigger them.
pub fn want_text_input() bool {
	return C.vgui_want_text_input() != 0
}

// key_pressed reports whether the printable key `ch` (A-Z / a-z / 0-9) was pressed this frame
// (no auto-repeat). Returns false for keys it can't map.
pub fn key_pressed(ch u8) bool {
	return C.vgui_key_pressed(int(ch)) != 0
}

// combo draws a dropdown of `items` and returns the selected index (== current when unchanged).
pub fn combo(label string, items []string, current int) int {
	if items.len == 0 {
		return current
	}
	mut ip := []&char{cap: items.len}
	for it in items {
		ip << it.str
	}
	return C.vgui_combo(label.str, unsafe { &&char(ip.data) }, items.len, current)
}

// --- widgets ---
pub fn set_next_window(x f32, y f32, w f32, h f32) {
	C.vgui_set_next_window(x, y, w, h)
}

// set_window_focus brings a docked window's tab to the front by name.
pub fn set_window_focus(name string) {
	C.vgui_set_window_focus(name.str)
}

// indent_x advances the cursor horizontally on the current line (left inset / spacer).
pub fn indent_x(w f32) {
	C.vgui_indent_x(w)
}

// indent_y nudges the cursor down (small top gap).
pub fn indent_y(h f32) {
	C.vgui_indent_y(h)
}

// push_frame_padding / push_window_padding + pop_style_var: scoped style overrides.
pub fn push_frame_padding(x f32, y f32) {
	C.vgui_push_frame_padding(x, y)
}

pub fn push_window_padding(x f32, y f32) {
	C.vgui_push_window_padding(x, y)
}

pub fn pop_style_var(n int) {
	C.vgui_pop_style_var(n)
}

// activity_style_push/pop wrap the activity bar in fixed dark colours (theme-independent,
// VS Code style). Push before the child begins, pop after it ends.
pub fn activity_style_push() {
	C.vgui_activity_style_push()
}

pub fn activity_style_pop() {
	C.vgui_activity_style_pop()
}

// dock_2col docks `left` and `right` side-by-side in the main window (one-time layout).
pub fn dock_2col(left string, right string, ratio f32) {
	C.vgui_dock_2col(left.str, right.str, ratio)
}

// dock_3 docks a | b | c across the main window (a=left aw, c=right cw, b=middle rest).
pub fn dock_3(a string, b string, c string, aw f32, cw f32) {
	C.vgui_dock_3(a.str, b.str, c.str, aw, cw)
}

// --- menu bar (above the dockspace) ---
pub fn menu_bar_begin() bool {
	return C.vgui_menu_bar_begin() == 1
}

pub fn menu_bar_end() {
	C.vgui_menu_bar_end()
}

pub fn menu_begin(label string) bool {
	return C.vgui_menu_begin(label.str) == 1
}

pub fn menu_end() {
	C.vgui_menu_end()
}

// begin_popup_context_item opens a right-click context menu on the last-submitted item.
// Returns true while open — render menu_item()s inside, then call end_popup(). `id` keeps
// each row's menu distinct.
pub fn begin_popup_context_item(id string) bool {
	return C.vgui_begin_popup_context_item(id.str) == 1
}

// begin_popup_context_window opens a right-click context menu anywhere in the current
// window or child (unlike _item, it needs no preceding widget) — console copy menus.
pub fn begin_popup_context_window() bool {
	return C.vgui_begin_popup_context_window() == 1
}

// clipboard_set puts text on the OS clipboard.
pub fn clipboard_set(s string) {
	C.vgui_clipboard_set(s.str)
}

// end_popup closes a begin_popup_context_item()/popup block.
pub fn end_popup() {
	C.vgui_end_popup()
}

// menu_item returns true the frame it is clicked.
pub fn menu_item(label string) bool {
	return C.vgui_menu_item(label.str) == 1
}

// menu_item_check renders a checkable item; returns the new checked state.
pub fn menu_item_check(label string, checked bool) bool {
	return C.vgui_menu_item_check(label.str, if checked { 1 } else { 0 }) == 1
}

// checkbox renders a checkbox with the current state; returns the (possibly toggled) state.
pub fn checkbox(label string, cur bool) bool {
	return C.vgui_checkbox(label.str, if cur { 1 } else { 0 }) == 1
}

pub fn text_colored(r u8, g u8, b u8, s string) {
	C.vgui_text_colored(int(r), int(g), int(b), s.str)
}

pub fn small_button(label string) bool {
	return C.vgui_small_button(label.str) == 1
}

pub fn spacing() {
	C.vgui_spacing()
}

pub fn separator() {
	C.vgui_separator()
}

// quit requests the main window to close (ends the run loop).
pub fn quit() {
	C.vgui_quit()
}

// --- ImPlot line plots (native pan/zoom/legend; auto-fit axes) ---
// plot_begin opens a plot of the given pixel height; returns false if not visible.
pub fn plot_begin(title string, height f32) bool {
	return C.vgui_plot_begin(title.str, height) == 1
}

// plot_begin_x opens a plot with a FIXED x (time) window [x_min,x_max] — a scrolling strip
// chart rather than the whole-history autofit; y still autofits. x_max<=x_min = x-autofit (full).
pub fn plot_begin_x(title string, height f32, x_min f64, x_max f64) bool {
	return C.vgui_plot_begin_x(title.str, height, x_min, x_max) == 1
}

// plot_line adds one series (x = time ms, y = value). Call between plot_begin/plot_end.
pub fn plot_line(name string, xs []f32, ys []f32) {
	n := if xs.len < ys.len { xs.len } else { ys.len }
	if n == 0 {
		return
	}
	C.vgui_plot_line(name.str, unsafe { &xs[0] }, unsafe { &ys[0] }, n)
}

// plot_begin_multi opens a plot with a fixed x-window and up to 3 real y-axes (n_yaxes 1..3),
// each auto-fitting to its own series, plus crosshairs. Add series with plot_line_axis.
pub fn plot_begin_multi(title string, height f32, x_min f64, x_max f64, n_yaxes int) bool {
	return C.vgui_plot_begin2(title.str, height, x_min, x_max, n_yaxes) == 1
}

// plot_line_axis adds a series bound to y-axis `axis` (0=Y1, 1=Y2, 2=Y3).
pub fn plot_line_axis(name string, xs []f32, ys []f32, axis int) {
	n := if xs.len < ys.len { xs.len } else { ys.len }
	if n == 0 {
		return
	}
	C.vgui_plot_line_axis(name.str, unsafe { &xs[0] }, unsafe { &ys[0] }, n, axis)
}

// plot_is_hovered reports whether the mouse is over the plot area (call between begin/end).
pub fn plot_is_hovered() bool {
	return C.vgui_plot_is_hovered() == 1
}

// plot_mouse_x returns the mouse position in x-axis (data) coordinates (call between begin/end).
pub fn plot_mouse_x() f64 {
	return C.vgui_plot_mouse_x()
}

pub fn plot_end() {
	C.vgui_plot_end()
}

// selectable renders a clickable row; returns true the frame it is clicked.
pub fn selectable(label string, selected bool) bool {
	return C.vgui_selectable(label.str, if selected { 1 } else { 0 }) == 1
}

// child_begin opens a scrollable bordered sub-region of the given pixel height (0 = fill).
// ALWAYS pair with child_end.
// child_fill is a borderless child filling the remaining content region.
pub fn child_fill(id string) {
	C.vgui_child_fill(id.str)
}

pub fn child_begin(id string, height f32) {
	C.vgui_child_begin(id.str, height)
}

// child_wh opens a fixed-size bordered child (w/h <= 0 = fill that axis). Pair with child_end.
pub fn child_wh(id string, w f32, h f32) {
	C.vgui_child_wh(id.str, w, h)
}

// toggle_button renders a button tinted when active (activity bar). w < 0 = stretch.
pub fn toggle_button(label string, active bool, w f32) bool {
	return C.vgui_toggle_button(label.str, if active { 1 } else { 0 }, w) == 1
}

pub fn child_end() {
	C.vgui_child_end()
}

// input_text edits `buf` (a persistent, NUL-terminated []u8 the caller owns) in place;
// returns true the frame the text changed. Read the value back with buf_str(buf).
pub fn input_text(label string, mut buf []u8) bool {
	if buf.len == 0 {
		return false
	}
	return C.vgui_input_text(label.str, unsafe { &char(&buf[0]) }, buf.len) == 1
}

pub fn console_input(label string, mut buf []u8) bool {
	if buf.len == 0 {
		return false
	}
	return C.vgui_console_input(label.str, unsafe { &char(&buf[0]) }, buf.len) == 1
}

// text_edit renders an EDITABLE multiline box `h` pixels high, writing into `buf` in place.
// Returns true on the frames where the text changed; false for an empty buffer, which ImGui
// cannot be handed.
pub fn text_edit(id string, mut buf []u8, h f32) bool {
	if buf.len == 0 {
		// InputTextMultiline writes into the caller's storage and requires a writable,
		// NUL-terminated buffer; a zero-length slice is a null pointer with no room, which
		// asserts inside ImGui rather than doing nothing.
		return false
	}
	return C.vgui_text_edit(id.str, &char(buf.data), buf.len, h) == 1
}

// console_text renders s as read-only but SELECTABLE console text (native mouse marking,
// Ctrl+A/Ctrl+C), sized to content so the enclosing child scrolls it. nlines = line count.
pub fn console_text(id string, s string, nlines int) {
	C.vgui_console_text(id.str, s.str, s.len, nlines)
}

// scroll_bottom pins the current child's scroll to the bottom (console output follows).
pub fn scroll_bottom() {
	C.vgui_scroll_bottom()
}

// input_double edits *v in place (numeric input, e.g. a signal value). Returns true on change.
pub fn input_double(label string, v &f64) bool {
	return C.vgui_input_double(label.str, v) == 1
}

// input_int edits *v in place (integer input with +/- steps). Returns true on change.
pub fn input_int(label string, v &int) bool {
	return C.vgui_input_int(label.str, v) == 1
}

// buf_str reads a NUL-terminated input buffer as a V string.
pub fn buf_str(buf []u8) string {
	mut n := 0
	for n < buf.len && buf[n] != 0 {
		n++
	}
	return buf[..n].bytestr()
}

pub fn set_next_item_width(w f32) {
	C.vgui_set_next_item_width(w)
}

// tree_node renders a collapsible header; if it returns true, render children and then
// call tree_pop().
pub fn tree_node(label string) bool {
	return C.vgui_tree_node(label.str) == 1
}

// tree_node_open is like tree_node but expanded by default (ImGuiCond_Once — the user can
// still collapse it). Good for overview trees like the Network panel.
pub fn tree_node_open(label string) bool {
	return C.vgui_tree_node_open(label.str) == 1
}

pub fn tree_pop() {
	C.vgui_tree_pop()
}

// --- DockBuilder: build a custom N-pane layout (see dock_left/right/up/down consts) ---
pub const dock_left = 0
pub const dock_right = 1
pub const dock_up = 2
pub const dock_down = 3

// dock_root resets the main dockspace; returns 0 if a layout is already persisted (skip).
pub fn dock_root() u32 {
	return C.vgui_dock_root()
}

// dock_split splits `node` in `dir`, giving the new pane `ratio` of it; `remainder`
// receives the opposite pane. Returns the new pane's node id.
pub fn dock_split(node u32, dir int, ratio f32, remainder &u32) u32 {
	return C.vgui_dock_split(node, dir, ratio, remainder)
}

pub fn dock_window(name string, node u32) {
	C.vgui_dock_window(name.str, node)
}

pub fn dock_finish(root u32) {
	C.vgui_dock_finish(root)
}

// begin opens a window; returns true if it is visible (active dock tab / not collapsed).
// Skip the content when false, but ALWAYS call end().
pub fn begin(title string) bool {
	return C.vgui_begin(title.str) == 1
}

// begin_closable is begin() with a close [X] in the title bar. Returns (visible, open):
// `open` goes false the frame the user clicks the X — the caller stores it back into its
// show-flag. Skip the content when `visible` is false, but ALWAYS call end().
pub fn begin_closable(title string, open bool) (bool, bool) {
	mut o := if open { 1 } else { 0 }
	vis := C.vgui_begin_closable(title.str, &o) == 1
	return vis, o != 0
}

pub fn end() {
	C.vgui_end()
}

// set_item_tooltip attaches a hover tooltip to the widget on the previous line.
pub fn set_item_tooltip(text string) {
	C.vgui_set_item_tooltip(text.str)
}

// help_marker draws a dim "(?)" that reveals `text` on hover — inline field help.
pub fn help_marker(text string) {
	C.vgui_help_marker(text.str)
}

pub fn text(s string) {
	C.vgui_text(s.str)
}

pub fn text_dim(s string) {
	C.vgui_text_dim(s.str)
}

pub fn button(label string) bool {
	return C.vgui_button(label.str) == 1
}

// button_big is a prominent coloured button at an explicit pixel size (w/h; 0 = auto),
// for a primary action like Start/Stop. r,g,b are 0-255.
pub fn button_big(label string, r int, g int, b int, w f32, h f32) bool {
	return C.vgui_button_big(label.str, r, g, b, w, h) == 1
}

// splitter_v: a draggable vertical divider between two side-by-side panes. Call it with
// same_line() after the left child_end and before the right child; pass the current left
// width and its min/max (px). Returns the updated width to store and reuse next frame.
pub fn splitter_v(id string, w f32, min_w f32, max_w f32) f32 {
	return C.vgui_splitter_v(id.str, w, min_w, max_w)
}

// content_avail_w is the width still available in the current window or child, in px. Use it
// to clamp a width you persisted against a panel that has since been docked or resized
// narrower — otherwise a pane sized in a big window can consume a small one entirely.
pub fn content_avail_w() f32 {
	return C.vgui_content_avail_w()
}

// is_item_deactivated_after_edit reports whether the PREVIOUS item stopped being edited this
// frame with a changed value — i.e. the edit is finished, not in progress.
//
// This matters whenever a handler derives one field from another. An input field commits on
// every keystroke, so typing "16" commits 1 and then 16; if the handler re-derives an anchor
// from each commit, the second keystroke is measured against an anchor the first already
// moved. Applying on deactivation instead sees only the final value.
pub fn is_item_deactivated_after_edit() bool {
	return C.vgui_is_item_deactivated_after_edit() != 0
}

pub fn same_line() {
	C.vgui_same_line()
}

pub fn separator_text(s string) {
	C.vgui_separator_text(s.str)
}

// table: begin -> col×N -> headers -> (row -> cell×N)… -> end
pub fn table_begin(id string, cols int) bool {
	return C.vgui_table_begin(id.str, cols) == 1
}

pub fn table_col(name string) {
	C.vgui_table_col(name.str)
}

pub fn table_headers() {
	C.vgui_table_headers()
}

pub fn table_row() {
	C.vgui_table_row()
}

pub fn table_cell(s string) {
	C.vgui_table_cell(s.str)
}

pub fn table_end() {
	C.vgui_table_end()
}

// table_next_col advances to the next column without emitting text (for arbitrary widgets).
pub fn table_next_col() {
	C.vgui_table_next_col()
}

// tree_node_table is a tree node inside a table cell (spans all columns for the click).
pub fn tree_node_table(label string) bool {
	return C.vgui_tree_node_table(label.str) == 1
}

// is_item_clicked reports whether the last-submitted item was clicked this frame.
pub fn is_item_clicked() bool {
	return C.vgui_is_item_clicked() == 1
}

// is_item_clicked_right reports whether the last-submitted item was RIGHT-clicked this frame.
pub fn is_item_clicked_right() bool {
	return C.vgui_is_item_clicked_right() == 1
}

// table_setup_col declares a column: width > 0 = fixed pixels, width <= 0 = stretch.
// Call for every column (after table_begin, before table_headers), then table_freeze_top.
pub fn table_setup_col(name string, width f32) {
	C.vgui_table_setup_col(name.str, width)
}

// table_freeze_top keeps the header row visible while the table body scrolls.
pub fn table_freeze_top() {
	C.vgui_table_freeze_top()
}

// swimlane draws a handler/task gantt in an ImPlot plot with native pan/zoom/time-axis. cursor_a
// / cursor_b are the two draggable measurement markers (µs); the widget mutates them (drag or the
// a/b keys) and the caller reads them back for the Δt readout.
pub fn swimlane(id string, labels []string, bars []Bar, links []Link, full_span_us f32, cursor_a &f64, cursor_b &f64) {
	if bars.len == 0 {
		return
	}
	mut lp := []&char{cap: labels.len}
	for l in labels {
		lp << l.str
	}
	mut lnp := unsafe { voidptr(nil) }
	if links.len > 0 {
		lnp = unsafe { voidptr(&links[0]) }
	}
	C.vgui_swimlane(id.str, labels.len, unsafe { &&char(lp.data) }, unsafe { &bars[0] },
		bars.len, lnp, links.len, full_span_us, cursor_a, cursor_b)
}

// rgba packs a colour into IM_COL32 order (ABGR in memory).
pub fn rgba(r u8, g u8, b u8, a u8) u32 {
	return (u32(a) << 24) | (u32(b) << 16) | (u32(g) << 8) | u32(r)
}
