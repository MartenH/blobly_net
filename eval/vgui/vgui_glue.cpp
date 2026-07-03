// vgui_glue — the C-ABI glue for the V `vgui` module. Lifecycle (GLFW + multi-viewport,
// event-driven) and the higher-level composites (the ImPlot swimlane) live here in C++
// where the ImGui/ImPlot C++ API is ergonomic; V binds cimgui directly for plain widgets.
#include "imgui.h"
#include "imgui_internal.h" // DockBuilder* (initial docked layout)
#include "implot.h"
#include "backends/imgui_impl_glfw.h"
#include "backends/imgui_impl_opengl3.h"
#ifdef IMGUI_ENABLE_FREETYPE
#include "misc/freetype/imgui_freetype.h"
#endif
#include <GLFW/glfw3.h>
#include <cstdio>
#include <cstdlib>

extern "C" {

typedef struct { float t0, dur; int lane; unsigned int color; int warn; int preempted; } VBar;

static GLFWwindow* g_win = nullptr;
static bool g_event_driven = true;
static const char* g_dump = nullptr;

// apply our style tweaks on top of imgui's palette (StyleColors* resets these, so this
// is re-run after every theme switch).
static void apply_style_tweaks() {
    ImGuiStyle& s = ImGui::GetStyle();
    // imgui defaults are very tight — loosen the whole UI for a desktop-app feel.
    s.WindowPadding   = ImVec2(10.0f, 8.0f);
    s.FramePadding    = ImVec2(10.0f, 7.0f);   // taller menu bar / buttons / inputs
    s.ItemSpacing     = ImVec2(10.0f, 8.0f);   // gap between widgets (rows breathe)
    s.ItemInnerSpacing= ImVec2(8.0f, 6.0f);
    s.CellPadding     = ImVec2(8.0f, 4.0f);    // table cell padding
    s.IndentSpacing   = 20.0f;
    s.ScrollbarSize   = 14.0f;
    s.GrabMinSize     = 12.0f;
    s.WindowRounding  = 5.0f; s.FrameRounding = 4.0f; s.PopupRounding = 4.0f;
    s.TabRounding     = 4.0f; s.GrabRounding  = 3.0f; s.ScrollbarRounding = 4.0f;
    s.WindowBorderSize= 1.0f; s.FrameBorderSize = 0.0f;
}
// hx() unpacks 0xRRGGBB (+ alpha) into an imgui ImVec4.
static ImVec4 hx(unsigned int c, float a = 1.0f) {
    return ImVec4(((c >> 16) & 0xFF) / 255.0f, ((c >> 8) & 0xFF) / 255.0f, (c & 0xFF) / 255.0f, a);
}
// VS Code "Dark+" flavoured palette — neutral #1E1E1E greys with a #007ACC blue accent
// (selection/headers/checks). Seeds every slot from StyleColorsDark first so slots not set
// below (text links, nav highlights) stay sane, then overlays the visible chrome.
static void style_vscode_dark() {
    ImGui::StyleColorsDark();
    const unsigned int bg0=0x1E1E1E, bg1=0x252526, bg2=0x2D2D2D, bg3=0x333333;
    const unsigned int input=0x3C3C3C, inputHov=0x464647, border=0x3C3C3C, borderLt=0x303031;
    const unsigned int text=0xD4D4D4, textDim=0x858585;
    const unsigned int accent=0x007ACC, accentHov=0x1177BB, sel=0x094771, selText=0x264F78;
    ImVec4* c = ImGui::GetStyle().Colors;
    c[ImGuiCol_Text]                 = hx(text);
    c[ImGuiCol_TextDisabled]         = hx(textDim);
    c[ImGuiCol_WindowBg]             = hx(bg0);
    c[ImGuiCol_ChildBg]              = hx(0, 0.0f);
    c[ImGuiCol_PopupBg]              = hx(bg1);
    c[ImGuiCol_Border]               = hx(border);
    c[ImGuiCol_BorderShadow]         = hx(0, 0.0f);
    c[ImGuiCol_FrameBg]              = hx(input);
    c[ImGuiCol_FrameBgHovered]       = hx(inputHov);
    c[ImGuiCol_FrameBgActive]        = hx(sel);
    c[ImGuiCol_TitleBg]              = hx(bg1);
    c[ImGuiCol_TitleBgActive]        = hx(bg1);
    c[ImGuiCol_TitleBgCollapsed]     = hx(bg1);
    c[ImGuiCol_MenuBarBg]            = hx(bg1);
    c[ImGuiCol_ScrollbarBg]          = hx(bg0);
    c[ImGuiCol_ScrollbarGrab]        = hx(0x4E4E4E);
    c[ImGuiCol_ScrollbarGrabHovered] = hx(0x5A5A5A);
    c[ImGuiCol_ScrollbarGrabActive]  = hx(0x646464);
    c[ImGuiCol_CheckMark]            = hx(accent);
    c[ImGuiCol_SliderGrab]           = hx(accent);
    c[ImGuiCol_SliderGrabActive]     = hx(accentHov);
    c[ImGuiCol_Button]               = hx(bg3);
    c[ImGuiCol_ButtonHovered]        = hx(0x454545);
    c[ImGuiCol_ButtonActive]         = hx(sel);
    c[ImGuiCol_Header]               = hx(sel);      // selected rows / tree / menu items
    c[ImGuiCol_HeaderHovered]        = hx(0x37373D);
    c[ImGuiCol_HeaderActive]         = hx(sel);
    c[ImGuiCol_Separator]            = hx(border);
    c[ImGuiCol_SeparatorHovered]     = hx(accent);
    c[ImGuiCol_SeparatorActive]      = hx(accent);
    c[ImGuiCol_ResizeGrip]           = hx(bg3);
    c[ImGuiCol_ResizeGripHovered]    = hx(accent);
    c[ImGuiCol_ResizeGripActive]     = hx(accentHov);
    c[ImGuiCol_PlotLines]            = hx(accent);
    c[ImGuiCol_PlotLinesHovered]     = hx(accentHov);
    c[ImGuiCol_PlotHistogram]        = hx(accent);
    c[ImGuiCol_PlotHistogramHovered] = hx(accentHov);
    c[ImGuiCol_TextSelectedBg]       = hx(selText);
    c[ImGuiCol_Tab]                  = hx(bg2);
    c[ImGuiCol_TabHovered]           = hx(0x3F3F46);
    c[ImGuiCol_TabSelected]          = hx(bg0);
    c[ImGuiCol_TabDimmed]            = hx(bg1);
    c[ImGuiCol_TabDimmedSelected]    = hx(bg0);
    c[ImGuiCol_DockingPreview]       = hx(accent, 0.4f);
    c[ImGuiCol_DockingEmptyBg]       = hx(bg0);
    c[ImGuiCol_TableHeaderBg]        = hx(bg1);
    c[ImGuiCol_TableBorderStrong]    = hx(border);
    c[ImGuiCol_TableBorderLight]     = hx(borderLt);
}
extern "C" void vgui_set_theme(int dark) {
    if (dark) style_vscode_dark(); else ImGui::StyleColorsLight();
    apply_style_tweaks();
}
// scale ALL UI text (1.0 = the loaded font's native size). imgui 1.92 moved this from
// io.FontGlobalScale to style.FontScaleMain.
extern "C" void vgui_set_font_scale(float s) { ImGui::GetStyle().FontScaleMain = s; }

int vgui_init(const char* title, int w, int h, int event_driven) {
    g_event_driven = event_driven != 0;
    if (!glfwInit()) return 1;
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 0);
    g_win = glfwCreateWindow(w, h, title, nullptr, nullptr);
    if (!g_win) return 2;
    glfwSetWindowPos(g_win, 60, 80);
    glfwMakeContextCurrent(g_win);
    glfwSwapInterval(1);
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImPlot::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable | ImGuiConfigFlags_ViewportsEnable;
#ifdef IMGUI_ENABLE_FREETYPE
    io.Fonts->SetFontLoader(ImGuiFreeType::GetFontLoader()); // crisp text (hinting + AA)
#endif
    vgui_set_theme(1);
    ImGui_ImplGlfw_InitForOpenGL(g_win, true);
    ImGui_ImplOpenGL3_Init("#version 130");
    return 0;
}

int vgui_running() {
    if (glfwWindowShouldClose(g_win)) return 0;
    if (g_event_driven) glfwWaitEventsTimeout(0.5);
    else glfwPollEvents();
    return 1;
}

static ImGuiID g_dockspace_id = 0;

// frame_begin opens a full-work-area HOST window with a menu bar; the app then draws the
// menu bar, an activity bar (a fixed-width child), and vgui_dockspace() which fills the
// rest. frame_end closes the host window. This is the VS Code shell layout.
// Menu-bar vertical padding — the host window's menu-bar height is baked at Begin() from
// FramePadding.y, so we push a bigger value just around Begin() (and again around the menu
// items in vgui_menu_bar_begin) to get a tall, easy-to-hit menu bar without inflating every
// other framed widget.
static float g_menu_pad_y = 16.0f;

void vgui_frame_begin() {
    ImGui_ImplOpenGL3_NewFrame();
    ImGui_ImplGlfw_NewFrame();
    ImGui::NewFrame();
    const ImGuiViewport* vp = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(vp->WorkPos);
    ImGui::SetNextWindowSize(vp->WorkSize);
    ImGui::SetNextWindowViewport(vp->ID);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0.0f, 0.0f));
    // taller menu bar: MenuBarHeight = FontSize + 2*FramePadding.y, computed in Begin()
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(ImGui::GetStyle().FramePadding.x, g_menu_pad_y));
    ImGuiWindowFlags f = ImGuiWindowFlags_MenuBar | ImGuiWindowFlags_NoDocking
        | ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoResize
        | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoBringToFrontOnFocus | ImGuiWindowFlags_NoNavFocus;
    ImGui::Begin("##host", nullptr, f);
    ImGui::PopStyleVar(4);
}

// dockspace creates the dockspace filling the remaining content region of the host window
// (call it AFTER the activity-bar child + SameLine).
void vgui_dockspace() {
    g_dockspace_id = ImGui::GetID("##dockspace");
    ImGui::DockSpace(g_dockspace_id, ImVec2(0.0f, 0.0f), ImGuiDockNodeFlags_None);
}

// vgui_dock_2col builds a one-time 2-column docked layout in the main dockspace: window
// `left` gets `ratio` of the width, `right` the rest. Both start DOCKED inside the main
// window (no stray OS windows); the user can still drag a tab out later. Idempotent — only
// builds when the node has no existing split (first run / fresh imgui.ini).
void vgui_dock_2col(const char* left, const char* right, float ratio) {
    if (g_dockspace_id == 0) return;
    ImGuiDockNode* node = ImGui::DockBuilderGetNode(g_dockspace_id);
    if (node && node->IsSplitNode()) return; // layout already set (persisted in imgui.ini)
    ImGui::DockBuilderRemoveNode(g_dockspace_id);
    ImGui::DockBuilderAddNode(g_dockspace_id, ImGuiDockNodeFlags_DockSpace);
    ImGui::DockBuilderSetNodeSize(g_dockspace_id, ImGui::GetMainViewport()->WorkSize);
    ImGuiID rightId;
    ImGuiID leftId = ImGui::DockBuilderSplitNode(g_dockspace_id, ImGuiDir_Left, ratio, NULL, &rightId);
    ImGui::DockBuilderDockWindow(left, leftId);
    ImGui::DockBuilderDockWindow(right, rightId);
    ImGui::DockBuilderFinish(g_dockspace_id);
}

void vgui_frame_end() {
    ImGui::End(); // host window (opened in frame_begin)
    ImGui::Render();
    int w,h; glfwGetFramebufferSize(g_win,&w,&h);
    glViewport(0,0,w,h); glClearColor(0.11f,0.12f,0.14f,1); glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
    if (g_dump) { // GL_BACK pre-swap (WSLg-proof capture)
        unsigned char* px=(unsigned char*)malloc(w*h*3);
        glReadBuffer(GL_BACK); glPixelStorei(GL_PACK_ALIGNMENT,1);
        glReadPixels(0,0,w,h,GL_RGB,GL_UNSIGNED_BYTE,px);
        FILE* f=fopen(g_dump,"wb");
        if(f){ fprintf(f,"P6\n%d %d\n255\n",w,h); for(int y=h-1;y>=0;y--) fwrite(px+y*w*3,1,w*3,f); fclose(f); }
        free(px); g_dump=nullptr;
    }
    ImGuiIO& io = ImGui::GetIO();
    if (io.ConfigFlags & ImGuiConfigFlags_ViewportsEnable) {
        GLFWwindow* b = glfwGetCurrentContext();
        ImGui::UpdatePlatformWindows(); ImGui::RenderPlatformWindowsDefault();
        glfwMakeContextCurrent(b);
    }
    glfwSwapBuffers(g_win);
}

void vgui_shutdown() {
    ImGui_ImplOpenGL3_Shutdown(); ImGui_ImplGlfw_Shutdown();
    ImPlot::DestroyContext(); ImGui::DestroyContext();
    if (g_win) glfwDestroyWindow(g_win);
    glfwTerminate();
}
double vgui_time() { return glfwGetTime(); }

// vgui_add_font loads a TTF as the default UI font (call after vgui_init, before the loop).
// Returns 1 on success. Caller should verify the file exists first (imgui asserts on a bad
// path). Rebuilds the atlas so the GL backend re-uploads it.
int vgui_add_font(const char* path, float size_px) {
    ImGuiIO& io = ImGui::GetIO();
    ImFont* f = io.Fonts->AddFontFromFileTTF(path, size_px);
    if (!f) return 0;
    io.FontDefault = f;
    ImGui_ImplOpenGL3_DestroyDeviceObjects(); // force the font texture to rebuild next frame
    return 1;
}
// vgui_wake posts an empty event to unblock glfwWaitEvents from ANOTHER thread — the
// event-driven equivalent of gui's queue_command. glfwPostEmptyEvent is one of the few
// thread-safe GLFW calls, so an RX/sim thread can call this to request a repaint.
void vgui_wake() { glfwPostEmptyEvent(); }
void vgui_dump_ppm(const char* path) { g_dump = path; }

// --- curated widget glue (scalar C ABI over imgui) ---
void vgui_set_next_window(float x, float y, float w, float h) {
    ImGui::SetNextWindowPos(ImVec2(x,y), ImGuiCond_Once);
    ImGui::SetNextWindowSize(ImVec2(w,h), ImGuiCond_Once);
}
// vgui_set_window_focus brings a docked window's tab to the front by name.
void vgui_set_window_focus(const char* name) { ImGui::SetWindowFocus(name); }
// --- menu bar (sits above the dockspace) ---
// match the item height to the taller bar (pushed in frame_begin) so File/View/Settings
// fill it and are hit-able across the full height.
int  vgui_menu_bar_begin() {
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(ImGui::GetStyle().FramePadding.x, g_menu_pad_y));
    if (ImGui::BeginMenuBar()) return 1;
    ImGui::PopStyleVar();
    return 0;
}
void vgui_menu_bar_end() { ImGui::EndMenuBar(); ImGui::PopStyleVar(); }
int  vgui_menu_begin(const char* label) { return ImGui::BeginMenu(label) ? 1 : 0; }
void vgui_menu_end() { ImGui::EndMenu(); }
int  vgui_menu_item(const char* label) { return ImGui::MenuItem(label) ? 1 : 0; }
int  vgui_menu_item_check(const char* label, int checked) {
    bool b = checked != 0;
    ImGui::MenuItem(label, nullptr, &b);
    return b ? 1 : 0;
}

// --- more widgets ---
int  vgui_checkbox(const char* label, int cur) { bool b = cur != 0; ImGui::Checkbox(label, &b); return b ? 1 : 0; }
void vgui_text_colored(int r, int g, int b, const char* s) {
    ImGui::TextColored(ImVec4(r/255.f, g/255.f, b/255.f, 1.f), "%s", s);
}
// NB: a normal-height Button, NOT ImGui::SmallButton — SmallButton zeroes vertical
// padding, so it sits shorter than the inputs/combos beside it. Uniform frame height
// (buttons == inputs == selects) matches vlang/gui and reads far cleaner in toolbars.
int  vgui_small_button(const char* label) { return ImGui::Button(label) ? 1 : 0; }
void vgui_spacing() { ImGui::Spacing(); }
void vgui_separator() { ImGui::Separator(); }
void vgui_quit() { if (g_win) glfwSetWindowShouldClose(g_win, 1); }

// vgui_dock_3 builds a one-time 3-column docked layout: `a` (left, aw fraction) | `b`
// (middle, rest) | `c` (right, cw fraction). All start docked inside the one main window.
void vgui_dock_3(const char* a, const char* b, const char* c, float aw, float cw) {
    if (g_dockspace_id == 0) return;
    ImGuiDockNode* node = ImGui::DockBuilderGetNode(g_dockspace_id);
    if (node && node->IsSplitNode()) return;
    ImGui::DockBuilderRemoveNode(g_dockspace_id);
    ImGui::DockBuilderAddNode(g_dockspace_id, ImGuiDockNodeFlags_DockSpace);
    ImGui::DockBuilderSetNodeSize(g_dockspace_id, ImGui::GetMainViewport()->WorkSize);
    ImGuiID rest, mid;
    ImGuiID left = ImGui::DockBuilderSplitNode(g_dockspace_id, ImGuiDir_Left, aw, NULL, &rest);
    ImGuiID right = ImGui::DockBuilderSplitNode(rest, ImGuiDir_Right, cw / (1.0f - aw), NULL, &mid);
    ImGui::DockBuilderDockWindow(a, left);
    ImGui::DockBuilderDockWindow(b, mid);
    ImGui::DockBuilderDockWindow(c, right);
    ImGui::DockBuilderFinish(g_dockspace_id);
}

// --- ImPlot line plot (live signal graphs) ---
int vgui_plot_begin(const char* title, float height) {
    if (ImPlot::BeginPlot(title, ImVec2(-1, height))) {
        ImPlot::SetupAxes("t (ms)", NULL, ImPlotAxisFlags_AutoFit, ImPlotAxisFlags_AutoFit);
        return 1;
    }
    return 0;
}
void vgui_plot_line(const char* name, const float* xs, const float* ys, int n) {
    ImPlot::PlotLine(name, xs, ys, n);
}
void vgui_plot_end() { ImPlot::EndPlot(); }

// selectable row/label; returns 1 the frame it is clicked.
int vgui_selectable(const char* label, int selected) {
    return ImGui::Selectable(label, selected != 0) ? 1 : 0;
}

// scrollable bordered child region of fixed pixel height (0 = fill). ALWAYS pair with
// vgui_child_end (imgui requires EndChild even when begin returns false/clipped).
// toggle_button: a button tinted with the active colour when `active` (activity bar).
// w<0 stretches to the content width.
int vgui_toggle_button(const char* label, int active, float w) {
    if (active) ImGui::PushStyleColor(ImGuiCol_Button, ImGui::GetStyleColorVec4(ImGuiCol_ButtonActive));
    bool c = ImGui::Button(label, ImVec2(w, 0.0f));
    if (active) ImGui::PopStyleColor();
    return c ? 1 : 0;
}
// fixed-size bordered child (for the activity bar). w/h <= 0 = fill that axis.
void vgui_child_wh(const char* id, float w, float h) {
    ImGui::BeginChild(id, ImVec2(w, h), ImGuiChildFlags_Borders);
}
void vgui_child_begin(const char* id, float height) {
    ImGui::BeginChild(id, ImVec2(0, height), ImGuiChildFlags_Borders);
}
void vgui_child_end() { ImGui::EndChild(); }

// single-line text input editing buf in place (caller owns a persistent NUL-terminated
// buffer of bufsize). Returns 1 the frame the text changed.
int vgui_input_text(const char* label, char* buf, int bufsize) {
    return ImGui::InputText(label, buf, (size_t)bufsize) ? 1 : 0;
}
// numeric input editing *v in place (for signal values). Returns 1 when changed.
int vgui_input_double(const char* label, double* v) {
    return ImGui::InputDouble(label, v, 0.0, 0.0, "%.3f") ? 1 : 0;
}
void vgui_set_next_item_width(float w) { ImGui::SetNextItemWidth(w); }
// advance the cursor horizontally on the current line (a left inset / spacer).
void vgui_indent_x(float w) { ImGui::SetCursorPosX(ImGui::GetCursorPosX() + w); }
// nudge the cursor down (small top gap).
void vgui_indent_y(float h) { ImGui::SetCursorPosY(ImGui::GetCursorPosY() + h); }
// scoped style overrides (e.g. tighter padding for the activity-bar buttons).
void vgui_push_frame_padding(float x, float y) { ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(x, y)); }
void vgui_push_window_padding(float x, float y) { ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(x, y)); }
void vgui_pop_style_var(int n) { ImGui::PopStyleVar(n); }

// collapsible tree node (grouped trace rows). If open, render children then call tree_pop.
int  vgui_tree_node(const char* label) { return ImGui::TreeNode(label) ? 1 : 0; }
void vgui_tree_pop() { ImGui::TreePop(); }

// --- general DockBuilder (build an N-pane layout from V) ---
// vgui_dock_root resets the main dockspace and returns its node id (0 if a layout is
// already persisted, so the caller skips rebuilding). dir: 0=left 1=right 2=up 3=down.
unsigned int vgui_dock_root() {
    if (g_dockspace_id == 0) return 0;
    ImGuiDockNode* node = ImGui::DockBuilderGetNode(g_dockspace_id);
    if (node && node->IsSplitNode()) return 0;
    ImGui::DockBuilderRemoveNode(g_dockspace_id);
    ImGui::DockBuilderAddNode(g_dockspace_id, ImGuiDockNodeFlags_DockSpace);
    ImGui::DockBuilderSetNodeSize(g_dockspace_id, ImGui::GetMainViewport()->WorkSize);
    return g_dockspace_id;
}
unsigned int vgui_dock_split(unsigned int node, int dir, float ratio, unsigned int* remainder) {
    ImGuiID rem;
    ImGuiID a = ImGui::DockBuilderSplitNode(node, (ImGuiDir)dir, ratio, NULL, &rem);
    if (remainder) *remainder = rem;
    return a;
}
void vgui_dock_window(const char* name, unsigned int node) { ImGui::DockBuilderDockWindow(name, node); }
void vgui_dock_finish(unsigned int root) { ImGui::DockBuilderFinish(root); }

// Returns 1 if the window is visible (active tab / not collapsed). Callers must skip the
// content when it returns 0 but ALWAYS call vgui_end (imgui pairs Begin/End unconditionally).
int vgui_begin(const char* title) { return ImGui::Begin(title) ? 1 : 0; }
void vgui_end() { ImGui::End(); }
void vgui_text(const char* s) { ImGui::TextUnformatted(s); }
void vgui_text_dim(const char* s) { ImGui::TextDisabled("%s", s); }
int  vgui_button(const char* label) { return ImGui::Button(label) ? 1 : 0; }
// a prominent coloured button at an explicit size (for the Start/Stop primary action).
// r,g,b are 0-255; w/h are pixels (0 = auto for that axis).
int vgui_button_big(const char* label, int r, int g, int b, float w, float h) {
    ImVec4 base(r / 255.f, g / 255.f, b / 255.f, 1.f);
    ImVec4 hov(base.x * 1.18f, base.y * 1.18f, base.z * 1.18f, 1.f);
    ImVec4 act(base.x * 0.85f, base.y * 0.85f, base.z * 0.85f, 1.f);
    ImGui::PushStyleColor(ImGuiCol_Button, base);
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, hov);
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, act);
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.f, 1.f, 1.f, 1.f));
    bool c = ImGui::Button(label, ImVec2(w, h));
    ImGui::PopStyleColor(4);
    return c ? 1 : 0;
}
void vgui_same_line() { ImGui::SameLine(); }
void vgui_separator_text(const char* s) { ImGui::SeparatorText(s); }
int  vgui_table_begin(const char* id, int cols) {
    // no RowBg (no zebra striping) — borders + scroll + resizable columns only.
    return ImGui::BeginTable(id, cols,
        ImGuiTableFlags_Borders|ImGuiTableFlags_ScrollY|ImGuiTableFlags_Resizable) ? 1 : 0;
}
// tree node inside a table cell (spans all columns for the click/arrow). Returns open.
int vgui_tree_node_table(const char* label) {
    return ImGui::TreeNodeEx(label, ImGuiTreeNodeFlags_SpanAllColumns) ? 1 : 0;
}
// true the frame the last-submitted item was clicked (for row selection).
int vgui_is_item_clicked() { return ImGui::IsItemClicked() ? 1 : 0; }
void vgui_table_col(const char* c) { ImGui::TableSetupColumn(c); }
void vgui_table_headers() { ImGui::TableHeadersRow(); }
void vgui_table_row() { ImGui::TableNextRow(); }
void vgui_table_cell(const char* s) { ImGui::TableNextColumn(); ImGui::TextUnformatted(s); }
void vgui_table_next_col() { ImGui::TableNextColumn(); } // advance without text (arbitrary widget)
// setup a column with a fixed pixel width (width > 0) or stretch (width <= 0).
void vgui_table_setup_col(const char* name, float width) {
    ImGui::TableSetupColumn(name, width > 0.0f ? ImGuiTableColumnFlags_WidthFixed
                                               : ImGuiTableColumnFlags_WidthStretch, width);
}
void vgui_table_freeze_top() { ImGui::TableSetupScrollFreeze(0, 1); } // header stays on scroll
void vgui_table_end() { ImGui::EndTable(); }
float vgui_fps() { return ImGui::GetIO().Framerate; }

// vgui_swimlane draws a handler/task gantt as an ImPlot plot: X = time (µs), Y = lanes.
// ImPlot gives native pan (drag), zoom (scroll/box), and a time axis for free — replacing
// the hand-rolled zoom buttons + scrollbar. Bars are drawn into the plot's draw list in
// pixel space via PlotToPixels, so they track pan/zoom exactly.
void vgui_swimlane(const char* plot_id, int n_lanes, const char** lane_labels,
                   const VBar* bars, int n_bars, float full_span_us) {
    ImPlotFlags pf = ImPlotFlags_NoLegend | ImPlotFlags_NoMouseText;
    if (ImPlot::BeginPlot(plot_id, ImVec2(-1, n_lanes * 26.0f + 40.0f), pf)) {
        // X axis in milliseconds (values are µs, scaled by 1e-3 for tick labels via format)
        ImPlot::SetupAxes("time (ms)", nullptr,
            ImPlotAxisFlags_None,
            ImPlotAxisFlags_NoGridLines | ImPlotAxisFlags_Invert); // lane 0 at top
        ImPlot::SetupAxisLimits(ImAxis_X1, 0, full_span_us, ImPlotCond_Once);
        ImPlot::SetupAxisLimits(ImAxis_Y1, n_lanes, 0, ImPlotCond_Once);
        ImPlot::SetupAxisFormat(ImAxis_X1, "%.0f");
        // lane tick labels
        static double ticks[64]; static const char* labels[64];
        int nt = n_lanes < 64 ? n_lanes : 64;
        for (int i=0;i<nt;i++){ ticks[i]=i+0.5; labels[i]=lane_labels[i]; }
        ImPlot::SetupAxisTicks(ImAxis_Y1, ticks, nt, labels);

        ImDrawList* dl = ImPlot::GetPlotDrawList();
        // faint lane bands
        for (int i=0;i<n_lanes;i++){
            if (i%2) {
                ImVec2 a = ImPlot::PlotToPixels(0.0, (double)i);
                ImVec2 b = ImPlot::PlotToPixels((double)full_span_us, (double)(i+1));
                dl->AddRectFilled(a, b, IM_COL32(255,255,255,10));
            }
        }
        ImPlot::PushPlotClipRect();
        for (int k=0;k<n_bars;k++){
            const VBar& bar = bars[k];
            ImVec2 p0 = ImPlot::PlotToPixels((double)bar.t0, (double)bar.lane + 0.12);
            ImVec2 p1 = ImPlot::PlotToPixels((double)(bar.t0+bar.dur), (double)bar.lane + 0.88);
            if (p1.x < p0.x + 1) p1.x = p0.x + 1; // 1px floor
            dl->AddRectFilled(p0, p1, bar.color, 1.5f);
            if (bar.warn) dl->AddRect(p0, p1, IM_COL32(233,60,60,255), 1.5f, 1.5f); // rounding, thickness
            if (bar.preempted && (p1.x - p0.x) >= 3) {
                for (float hx=p0.x+3; hx<p1.x; hx+=5)
                    dl->AddLine(ImVec2(hx,p0.y), ImVec2(hx-(p1.y-p0.y),p1.y), IM_COL32(255,255,255,150), 1.0f);
            }
        }
        ImPlot::PopPlotClipRect();
        ImPlot::EndPlot();
    }
}

} // extern "C"
