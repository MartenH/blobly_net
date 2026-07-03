// vgui — a small V binding for Dear ImGui + ImPlot (docking / multi-viewport, GLFW/GL3).
// Clean V API over a curated scalar C ABI (vgui_glue.cpp) sitting on cimgui/cimplot — the
// same wrap-C-in-a-facade pattern blobly_net uses for Lua/SocketCAN, so the V<->C surface
// stays small and stable (unlike a raw ~800-fn cimgui binding). Reusable across projects.
module vgui

#flag -I@VMODROOT
#flag @VMODROOT/libvgui_c.a
// Linux/WSL: GLFW (X11) + GL + the C++ runtime the imgui/implot objects need.
#flag linux -lglfw -lGL -lstdc++ -ldl -lm
// Windows (mingw): link GLFW3 *statically* (-l:libglfw3.a, so no glfw3.dll/winpthread
// to ship) + its Win32 deps (gdi32/imm32/shell32/user32) + opengl32; -lstdc++ for the
// imgui/implot C++ objects, static libstdc++/libgcc so the exe carries no MinGW runtime
// DLLs (deps end up: kernel32/user32/gdi32/shell32/opengl32/msvcrt only). Multi-viewport
// is native Win32 (no X11). Verified: mingw-w64 gcc 16.1.0, self-contained exe, GL 4.6.
#flag windows -static -l:libglfw3.a -lopengl32 -lgdi32 -limm32 -lshell32 -luser32 -lstdc++ -static-libstdc++ -static-libgcc
#include "vgui.h"

// Bar mirrors the C `VBar` (SoA-free struct passed by pointer; C-compatible layout).
pub struct Bar {
pub:
	t0        f32 // start, µs (relative to capture start)
	dur       f32 // cpu_us
	lane      int
	color     u32 // packed IM_COL32 (RGBA, little-endian ABGR in memory)
	warn      int // overran/saturated -> red outline
	preempted int // hatch overlay
}

fn C.vgui_init(&char, int, int, int) int
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
fn C.vgui_swimlane(&char, int, &&char, voidptr, int, f32)
fn C.vgui_set_next_window(f32, f32, f32, f32)
fn C.vgui_dock_2col(&char, &char, f32)
fn C.vgui_dock_3(&char, &char, &char, f32, f32)
fn C.vgui_menu_bar_begin() int
fn C.vgui_menu_bar_end()
fn C.vgui_menu_begin(&char) int
fn C.vgui_menu_end()
fn C.vgui_menu_item(&char) int
fn C.vgui_menu_item_check(&char, int) int
fn C.vgui_checkbox(&char, int) int
fn C.vgui_text_colored(int, int, int, &char)
fn C.vgui_small_button(&char) int
fn C.vgui_spacing()
fn C.vgui_separator()
fn C.vgui_quit()
fn C.vgui_plot_begin(&char, f32) int
fn C.vgui_plot_line(&char, &f32, &f32, int)
fn C.vgui_plot_end()
fn C.vgui_selectable(&char, int) int
fn C.vgui_child_begin(&char, f32)
fn C.vgui_toggle_button(&char, int, f32) int
fn C.vgui_child_wh(&char, f32, f32)
fn C.vgui_child_end()
fn C.vgui_input_text(&char, &char, int) int
fn C.vgui_set_next_item_width(f32)
fn C.vgui_tree_node(&char) int
fn C.vgui_tree_pop()
fn C.vgui_dock_root() u32
fn C.vgui_dock_split(u32, int, f32, &u32) u32
fn C.vgui_dock_window(&char, u32)
fn C.vgui_dock_finish(u32)
fn C.vgui_begin(&char) int
fn C.vgui_end()
fn C.vgui_text(&char)
fn C.vgui_text_dim(&char)
fn C.vgui_button(&char) int
fn C.vgui_same_line()
fn C.vgui_separator_text(&char)
fn C.vgui_table_begin(&char, int) int
fn C.vgui_table_col(&char)
fn C.vgui_table_headers()
fn C.vgui_table_row()
fn C.vgui_table_cell(&char)
fn C.vgui_table_next_col()
fn C.vgui_tree_node_table(&char) int
fn C.vgui_table_setup_col(&char, f32)
fn C.vgui_table_freeze_top()
fn C.vgui_table_end()
fn C.vgui_fps() f32

// --- lifecycle ---
pub fn init(title string, w int, h int, event_driven bool) bool {
	return C.vgui_init(title.str, w, h, if event_driven { 1 } else { 0 }) == 0
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

// --- widgets ---
pub fn set_next_window(x f32, y f32, w f32, h f32) {
	C.vgui_set_next_window(x, y, w, h)
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

// plot_line adds one series (x = time ms, y = value). Call between plot_begin/plot_end.
pub fn plot_line(name string, xs []f32, ys []f32) {
	n := if xs.len < ys.len { xs.len } else { ys.len }
	if n == 0 {
		return
	}
	C.vgui_plot_line(name.str, unsafe { &xs[0] }, unsafe { &ys[0] }, n)
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
	return C.vgui_input_text(label.str, unsafe { &char(&buf[0]) }, buf.len) == 1
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

pub fn end() {
	C.vgui_end()
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

// table_setup_col declares a column: width > 0 = fixed pixels, width <= 0 = stretch.
// Call for every column (after table_begin, before table_headers), then table_freeze_top.
pub fn table_setup_col(name string, width f32) {
	C.vgui_table_setup_col(name.str, width)
}

// table_freeze_top keeps the header row visible while the table body scrolls.
pub fn table_freeze_top() {
	C.vgui_table_freeze_top()
}

// swimlane draws a handler/task gantt in an ImPlot plot with native pan/zoom/time-axis.
pub fn swimlane(id string, labels []string, bars []Bar, full_span_us f32) {
	if bars.len == 0 {
		return
	}
	mut lp := []&char{cap: labels.len}
	for l in labels {
		lp << l.str
	}
	C.vgui_swimlane(id.str, labels.len, unsafe { &&char(lp.data) }, unsafe { &bars[0] },
		bars.len, full_span_us)
}

// rgba packs a colour into IM_COL32 order (ABGR in memory).
pub fn rgba(r u8, g u8, b u8, a u8) u32 {
	return (u32(a) << 24) | (u32(b) << 16) | (u32(g) << 8) | u32(r)
}
