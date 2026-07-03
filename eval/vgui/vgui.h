#ifndef VGUI_H
#define VGUI_H
typedef struct { float t0, dur; int lane; unsigned int color; int warn; int preempted; } VBar;
#ifdef __cplusplus
extern "C" {
#endif
int vgui_init(const char* title, int w, int h, int event_driven);
int vgui_running(void);
void vgui_frame_begin(void);
void vgui_frame_end(void);
void vgui_shutdown(void);
double vgui_time(void);
void vgui_wake(void);
void vgui_dump_ppm(const char* path);
void vgui_swimlane(const char* id, int n_lanes, const char** lane_labels,
                   const VBar* bars, int n_bars, float full_span_us);
void vgui_set_next_window(float,float,float,float);
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
void vgui_quit(void);
void vgui_dock_3(const char* a, const char* b, const char* c, float aw, float cw);
void vgui_begin(const char* title);
void vgui_end(void);
void vgui_text(const char* s);
void vgui_text_dim(const char* s);
int  vgui_button(const char* label);
void vgui_same_line(void);
void vgui_separator_text(const char* s);
int  vgui_table_begin(const char* id, int cols);
void vgui_table_col(const char* c);
void vgui_table_headers(void);
void vgui_table_row(void);
void vgui_table_cell(const char* s);
void vgui_table_end(void);
float vgui_fps(void);
#ifdef __cplusplus
}
#endif
#endif
