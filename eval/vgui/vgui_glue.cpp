// vgui_glue — the C-ABI glue for the V `vgui` module. Lifecycle (GLFW + multi-viewport,
// event-driven) and the higher-level composites (the ImPlot swimlane) live here in C++
// where the ImGui/ImPlot C++ API is ergonomic; V binds cimgui directly for plain widgets.
#include "imgui.h"
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
    ImGui::StyleColorsDark();
    ImGuiStyle& s = ImGui::GetStyle();
    s.WindowRounding = 4.0f; s.FrameRounding = 3.0f;
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

void vgui_frame_begin() {
    ImGui_ImplOpenGL3_NewFrame();
    ImGui_ImplGlfw_NewFrame();
    ImGui::NewFrame();
    ImGui::DockSpaceOverViewport(0, ImGui::GetMainViewport());
}

void vgui_frame_end() {
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
void vgui_begin(const char* title) { ImGui::Begin(title); }
void vgui_end() { ImGui::End(); }
void vgui_text(const char* s) { ImGui::TextUnformatted(s); }
void vgui_text_dim(const char* s) { ImGui::TextDisabled("%s", s); }
int  vgui_button(const char* label) { return ImGui::Button(label) ? 1 : 0; }
void vgui_same_line() { ImGui::SameLine(); }
void vgui_separator_text(const char* s) { ImGui::SeparatorText(s); }
int  vgui_table_begin(const char* id, int cols) {
    return ImGui::BeginTable(id, cols,
        ImGuiTableFlags_Borders|ImGuiTableFlags_RowBg|ImGuiTableFlags_ScrollY|ImGuiTableFlags_Resizable) ? 1 : 0;
}
void vgui_table_col(const char* c) { ImGui::TableSetupColumn(c); }
void vgui_table_headers() { ImGui::TableHeadersRow(); }
void vgui_table_row() { ImGui::TableNextRow(); }
void vgui_table_cell(const char* s) { ImGui::TableNextColumn(); ImGui::TextUnformatted(s); }
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
