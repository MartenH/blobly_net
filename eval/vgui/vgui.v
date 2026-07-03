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
fn C.vgui_frame_end()
fn C.vgui_shutdown()
fn C.vgui_time() f64
fn C.vgui_wake()
fn C.vgui_dump_ppm(&char)
fn C.vgui_swimlane(&char, int, &&char, voidptr, int, f32)
fn C.vgui_set_next_window(f32, f32, f32, f32)
fn C.vgui_dock_2col(&char, &char, f32)
fn C.vgui_begin(&char)
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

pub fn begin(title string) {
	C.vgui_begin(title.str)
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
