#ifndef VGUI_H
#define VGUI_H
typedef struct { float t0, dur; int lane; unsigned int color; int warn; int preempted; } VBar;
#ifdef __cplusplus
extern "C" {
#endif
int vgui_init(const char* title, int w, int h, int event_driven);
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
                   const VBar* bars, int n_bars, float full_span_us);
void vgui_set_next_window(float,float,float,float);
void vgui_set_window_focus(const char*);
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
void vgui_spacing(void);
void vgui_separator(void);
void vgui_quit(void);
void vgui_dock_3(const char* a, const char* b, const char* c, float aw, float cw);
int  vgui_plot_begin(const char* title, float height);
void vgui_plot_line(const char* name, const float* xs, const float* ys, int n);
void vgui_plot_end(void);
int  vgui_selectable(const char* label, int selected);
void vgui_child_begin(const char* id, float height);
int  vgui_toggle_button(const char* label, int active, float w);
void vgui_child_wh(const char* id, float w, float h);
void vgui_child_end(void);
int  vgui_input_text(const char* label, char* buf, int bufsize);
int  vgui_input_double(const char* label, double* v);
void vgui_set_next_item_width(float w);
int  vgui_tree_node(const char* label);
void vgui_tree_pop(void);
unsigned int vgui_dock_root(void);
unsigned int vgui_dock_split(unsigned int node, int dir, float ratio, unsigned int* remainder);
void vgui_dock_window(const char* name, unsigned int node);
void vgui_dock_finish(unsigned int root);
int  vgui_begin(const char* title);
void vgui_end(void);
void vgui_text(const char* s);
void vgui_text_dim(const char* s);
int  vgui_button(const char* label);
int  vgui_button_big(const char* label, int r, int g, int b, float w, float h);
void vgui_same_line(void);
void vgui_separator_text(const char* s);
int  vgui_table_begin(const char* id, int cols);
void vgui_table_col(const char* c);
void vgui_table_headers(void);
void vgui_table_row(void);
void vgui_table_cell(const char* s);
void vgui_table_next_col(void);
int  vgui_tree_node_table(const char* label);
void vgui_table_setup_col(const char* name, float width);
void vgui_table_freeze_top(void);
void vgui_table_end(void);
float vgui_fps(void);
#ifdef __cplusplus
}
#endif
#endif
