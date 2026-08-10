#ifndef VGUI_H
#define VGUI_H
typedef struct { float t0, dur; int lane; unsigned int color; int warn; int preempted; int style; } VBar;
typedef struct { float x; int lane_from, lane_to; } VLink; /* a preemption cut: victim -> preemptor */
#ifdef __cplusplus
extern "C" {
#endif
int vgui_init(const char* title, int w, int h, int event_driven);
void vgui_set_window_icon(int w, int h, const unsigned char* rgba);
int  vgui_plot_begin_x(const char* title, float height, double x_min, double x_max);
int  vgui_is_item_clicked_right(void);
int vgui_running(void);
void vgui_frame_begin(void);
void vgui_dockspace(void);
void vgui_frame_end(void);
void vgui_shutdown(void);
double vgui_time(void);
void vgui_wake(void);
int  vgui_add_font(const char* path, float size_px);
void vgui_set_theme(int dark);
void vgui_set_font_scale(float s);
void vgui_dump_ppm(const char* path);
void vgui_swimlane(const char* id, int n_lanes, const char** lane_labels,
                   const VBar* bars, int n_bars,
                   const VLink* links, int n_links, float full_span_us,
                   double* cursor_a, double* cursor_b);
void vgui_set_next_window(float,float,float,float);
void vgui_set_window_focus(const char*);
void vgui_indent_x(float w);
void vgui_indent_y(float h);
void vgui_push_frame_padding(float x, float y);
void vgui_push_window_padding(float x, float y);
void vgui_pop_style_var(int n);
void vgui_activity_style_push(void);
void vgui_activity_style_pop(void);
void vgui_dock_2col(const char* left, const char* right, float ratio);
int  vgui_menu_bar_begin(void);
void vgui_menu_bar_end(void);
int  vgui_menu_begin(const char* label);
void vgui_menu_end(void);
int  vgui_menu_item(const char* label);
int  vgui_menu_item_check(const char* label, int checked);
int  vgui_checkbox(const char* label, int cur);
void vgui_text_colored(int r, int g, int b, const char* s);
int  vgui_small_button(const char* label);
int  vgui_begin_popup_context_item(const char* id);
int  vgui_begin_popup_context_window(void);
void vgui_clipboard_set(const char* s);
void vgui_end_popup(void);
void vgui_spacing(void);
void vgui_separator(void);
void vgui_quit(void);
void vgui_dock_3(const char* a, const char* b, const char* c, float aw, float cw);
int  vgui_plot_begin(const char* title, float height);
int  vgui_plot_begin2(const char* title, float height, double x_min, double x_max, int n_yaxes);
void vgui_plot_line_axis(const char* name, const float* xs, const float* ys, int n, int axis);
int  vgui_plot_is_hovered(void);
double vgui_plot_mouse_x(void);
void vgui_plot_line(const char* name, const float* xs, const float* ys, int n);
void vgui_plot_end(void);
int  vgui_selectable(const char* label, int selected);
void vgui_child_begin(const char* id, float height);
void vgui_child_fill(const char* id);
int  vgui_toggle_button(const char* label, int active, float w);
void vgui_child_wh(const char* id, float w, float h);
void vgui_child_end(void);
int  vgui_input_text(const char* label, char* buf, int bufsize);
int  vgui_console_input(const char* label, char* buf, int bufsize);
void vgui_scroll_bottom(void);
void vgui_console_text(const char* id, const char* text, int len, int nlines);
int  vgui_input_double(const char* label, double* v);
int  vgui_input_int(const char* label, int* v);
void vgui_set_next_item_width(float w);
int  vgui_tree_node(const char* label);
int  vgui_tree_node_open(const char* label);
void vgui_tree_pop(void);
unsigned int vgui_dock_root(void);
unsigned int vgui_dock_split(unsigned int node, int dir, float ratio, unsigned int* remainder);
void vgui_dock_window(const char* name, unsigned int node);
void vgui_dock_finish(unsigned int root);
int  vgui_begin(const char* title);
int  vgui_begin_closable(const char* title, int* p_open);
void vgui_end(void);
void vgui_set_item_tooltip(const char* text);
void vgui_help_marker(const char* text);
void vgui_text(const char* s);
void vgui_text_dim(const char* s);
int  vgui_button(const char* label);
int  vgui_button_big(const char* label, int r, int g, int b, float w, float h);
// vertical splitter handle between two side-by-side panes; returns the updated left width (px).
float vgui_splitter_v(const char* id, float w, float min_w, float max_w);
void vgui_same_line(void);
void vgui_separator_text(const char* s);
int  vgui_table_begin(const char* id, int cols);
void vgui_table_col(const char* c);
void vgui_table_headers(void);
void vgui_table_row(void);
void vgui_table_cell(const char* s);
void vgui_table_next_col(void);
int  vgui_tree_node_table(const char* label);
int  vgui_is_item_clicked(void);
void vgui_table_setup_col(const char* name, float width);
void vgui_table_freeze_top(void);
void vgui_table_end(void);
float vgui_fps(void);
int  vgui_want_text_input(void);
int  vgui_key_pressed(int ch);
int  vgui_combo(const char* label, const char** items, int n, int current);
#ifdef __cplusplus
}
#endif
#endif
