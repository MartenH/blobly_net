// vgui_glue — the C-ABI glue for the V `vgui` module. Lifecycle (GLFW + multi-viewport,
// event-driven) and the higher-level composites (the ImPlot swimlane) live here in C++
// where the ImGui/ImPlot C++ API is ergonomic; V binds cimgui directly for plain widgets.
#include "imgui.h"
#include "imgui_internal.h" // DockBuilder* (initial docked layout)
#include "implot.h"
#include "backends/imgui_impl_glfw.h"
#include "backends/imgui_impl_opengl3.h"
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
    s.WindowRounding = 4.0f; s.FrameRounding = 3.0f;
    s.FramePadding = ImVec2(8.0f, 6.0f);   // taller menu bar / buttons / inputs
    s.ItemSpacing  = ImVec2(8.0f, 6.0f);
    s.CellPadding  = ImVec2(6.0f, 3.0f);
}
// Adobe Spectrum palette, vendored (no dependency on Adobe's imgui fork — this is just a
// color table, and ImGuiCol_ slots are stable). Values from adobe/imgui imgui_spectrum.cpp.
// hx() unpacks 0xRRGGBB (+ alpha) into imgui's linear-ish sRGB ImVec4.
static ImVec4 hx(unsigned int c, float a = 1.0f) {
    return ImVec4(((c >> 16) & 0xFF) / 255.0f, ((c >> 8) & 0xFF) / 255.0f, (c & 0xFF) / 255.0f, a);
}
// Spectrum theme. Seeds ALL slots from the stock preset first (so modern slots imgui added
// after Spectrum — table borders, tab overlines, text links — stay sane), then overlays the
// Spectrum grays + blue accent over the visible chrome.
static void style_spectrum(bool dark) {
    if (dark) ImGui::StyleColorsDark(); else ImGui::StyleColorsLight();
    // gray50..gray900 + blue400..700 for the chosen mode
    unsigned int g50, g75, g100, g200, g300, g400, g500, g600, g700, g800, g900;
    unsigned int b400, b500, b600, b700;
    if (dark) {
        g50=0x252525; g75=0x2F2F2F; g100=0x323232; g200=0x393939; g300=0x3E3E3E; g400=0x4D4D4D;
        g500=0x5C5C5C; g600=0x7B7B7B; g700=0x999999; g800=0xCDCDCD; g900=0xFFFFFF;
        b400=0x2680EB; b500=0x378EF0; b600=0x4B9CF5; b700=0x5AA9FA;
    } else {
        g50=0xFFFFFF; g75=0xFAFAFA; g100=0xF5F5F5; g200=0xEAEAEA; g300=0xE1E1E1; g400=0xCACACA;
        g500=0xB3B3B3; g600=0x8E8E8E; g700=0x707070; g800=0x4B4B4B; g900=0x2C2C2C;
        b400=0x2680EB; b500=0x1473E6; b600=0x0D66D0; b700=0x095ABA;
    }
    ImVec4* c = ImGui::GetStyle().Colors;
    c[ImGuiCol_Text]                 = hx(g800);
    c[ImGuiCol_TextDisabled]         = hx(g500);
    c[ImGuiCol_WindowBg]             = hx(g100);
    c[ImGuiCol_PopupBg]              = hx(g50);
    c[ImGuiCol_Border]               = hx(g300);
    c[ImGuiCol_BorderShadow]         = hx(0, 0.0f);
    c[ImGuiCol_FrameBg]              = hx(g75);
    c[ImGuiCol_FrameBgHovered]       = hx(g50);
    c[ImGuiCol_FrameBgActive]        = hx(g200);
    c[ImGuiCol_TitleBg]              = hx(g300);
    c[ImGuiCol_TitleBgActive]        = hx(g200);
    c[ImGuiCol_TitleBgCollapsed]     = hx(g400);
    c[ImGuiCol_MenuBarBg]            = hx(g100);
    c[ImGuiCol_ScrollbarBg]          = hx(g100);
    c[ImGuiCol_ScrollbarGrab]        = hx(g400);
    c[ImGuiCol_ScrollbarGrabHovered] = hx(g600);
    c[ImGuiCol_ScrollbarGrabActive]  = hx(g700);
    c[ImGuiCol_CheckMark]            = hx(b500);
    c[ImGuiCol_SliderGrab]           = hx(g700);
    c[ImGuiCol_SliderGrabActive]     = hx(g800);
    c[ImGuiCol_Button]               = hx(g75);
    c[ImGuiCol_ButtonHovered]        = hx(g50);
    c[ImGuiCol_ButtonActive]         = hx(g200);
    c[ImGuiCol_Header]               = hx(b400);   // selected rows / tree / menu items
    c[ImGuiCol_HeaderHovered]        = hx(b500);
    c[ImGuiCol_HeaderActive]         = hx(b600);
    c[ImGuiCol_Separator]            = hx(g400);
    c[ImGuiCol_SeparatorHovered]     = hx(g600);
    c[ImGuiCol_SeparatorActive]      = hx(g700);
    c[ImGuiCol_ResizeGrip]           = hx(g400);
    c[ImGuiCol_ResizeGripHovered]    = hx(g600);
    c[ImGuiCol_ResizeGripActive]     = hx(g700);
    c[ImGuiCol_PlotLines]            = hx(b400);
    c[ImGuiCol_PlotLinesHovered]     = hx(b600);
    c[ImGuiCol_PlotHistogram]        = hx(b400);
    c[ImGuiCol_PlotHistogramHovered] = hx(b600);
    c[ImGuiCol_TextSelectedBg]       = hx(b400, 0.33f);
    c[ImGuiCol_Tab]                  = hx(g300);
    c[ImGuiCol_TabHovered]           = hx(b500);
    c[ImGuiCol_TabSelected]          = hx(b500);
    c[ImGuiCol_TabDimmed]            = hx(g400);
    c[ImGuiCol_TabDimmedSelected]    = hx(b700);
    // modern slots Spectrum predates — keep them on-palette for our docked, table-heavy UI
    c[ImGuiCol_DockingPreview]       = hx(b400, 0.5f);
    c[ImGuiCol_DockingEmptyBg]       = hx(g200);
    c[ImGuiCol_TableHeaderBg]        = hx(g200);
    c[ImGuiCol_TableBorderStrong]    = hx(g400);
    c[ImGuiCol_TableBorderLight]     = hx(g300);
}
extern "C" void vgui_set_theme(int dark) {
    style_spectrum(dark != 0);
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
    ImGuiWindowFlags f = ImGuiWindowFlags_MenuBar | ImGuiWindowFlags_NoDocking
        | ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoResize
        | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoBringToFrontOnFocus | ImGuiWindowFlags_NoNavFocus;
    ImGui::Begin("##host", nullptr, f);
    ImGui::PopStyleVar(3);
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
int  vgui_menu_bar_begin() { return ImGui::BeginMenuBar() ? 1 : 0; } // host-window menu bar
void vgui_menu_bar_end() { ImGui::EndMenuBar(); }
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
int  vgui_small_button(const char* label) { return ImGui::SmallButton(label) ? 1 : 0; }
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
