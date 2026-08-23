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
#include <cstring>
#include <cstdlib>

extern "C" {

typedef struct { float t0, dur; int lane; unsigned int color; int warn; int preempted; int style; } VBar;
typedef struct { float x; int lane_from, lane_to; } VLink;

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

// jump to an absolute column. TableNextColumn-only navigation forces callers that skip columns
// to count them — a count that silently lands text in the wrong column when a column is added.
extern "C" void vgui_table_set_col(int n) { ImGui::TableSetColumnIndex(n); }

int vgui_init(const char* title, int w, int h, int event_driven) {
    g_event_driven = event_driven != 0;
    if (!glfwInit()) return 1;
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 0);
    // A FIXED size, exactly as asked — no maximize, no clamping. Both were tried and both
    // created failures worse than the one they solved: the maximized first frame scrambled
    // dock layouts persisted at the old size (panels in a corner, the rest black), and a
    // "helpful" work-area clamp made the headless screenshot geometry depend on the monitor
    // it rendered on, planted windows under docked taskbars by discarding the work-area
    // origin, and went negative on tiny displays. The caller states a size; it gets it.
    if (w <= 0) w = 1500;
    if (h <= 0) h = 850;
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

// vgui_set_window_icon sets the OS window / taskbar icon from a w×h RGBA8 buffer (the caller
// owns the pixels; GLFW copies them). Call after vgui_init. On macOS GLFW ignores this (uses
// the .app bundle icon), which is fine.
void vgui_set_window_icon(int w, int h, const unsigned char* rgba) {
    if (!g_win || !rgba || w <= 0 || h <= 0) return;
    GLFWimage img;
    img.width = w; img.height = h;
    img.pixels = (unsigned char*)rgba;
    glfwSetWindowIcon(g_win, 1, &img);
}

// vgui_set_window_icons is set_window_icon with several candidate sizes in one call, so the
// OS picks the native one per context (Windows: taskbar 32, title bar 16) instead of scaling
// a single bitmap. One call replaces the whole set — GLFW does not accumulate across calls.
void vgui_set_window_icons(int count, const int* w, const int* h,
                           const unsigned char* const* rgba) {
    if (!g_win || !w || !h || !rgba || count <= 0) return;
    if (count > 8) count = 8; // keep the best 8 rather than dropping the whole set
    GLFWimage imgs[8];
    int n = 0;
    for (int i = 0; i < count; i++) {
        if (!rgba[i] || w[i] <= 0 || h[i] <= 0) continue;
        imgs[n].width = w[i]; imgs[n].height = h[i];
        imgs[n].pixels = (unsigned char*)rgba[i];
        n++;
    }
    if (n) glfwSetWindowIcon(g_win, n, imgs);
}

// vgui_create_texture uploads a w×h RGBA8 buffer as a GL texture and returns its id (0 on
// failure). GL 1.1 calls only — no loader needed on Windows, where GLFW's header gives us
// nothing newer. Needs the GL context, so call after vgui_init; the caller keeps the id for
// the process lifetime (nothing here ever frees one).
unsigned int vgui_create_texture(int w, int h, const unsigned char* rgba) {
    if (!g_win || !rgba || w <= 0 || h <= 0) return 0;
    GLuint tex = 0;
    glGenTextures(1, &tex);
    if (!tex) return 0;
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
#ifndef GL_CLAMP_TO_EDGE
#define GL_CLAMP_TO_EDGE 0x812F /* GL 1.2 token; Windows' GL 1.1 header may lack it */
#endif
    // Clamp, or GL_REPEAT bleeds the opposite edge into border texels under linear
    // filtering — the wordmark's ink touches all four borders.
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    return (unsigned int)tex;
}

// vgui_menu_image draws a texture as a menu-bar item: current font size tall, width from the
// texture's aspect ratio, multiplied by the theme's text color — a white-on-transparent mark
// is the theme's ink by construction, and follows a theme switch with no caller involvement.
void vgui_menu_image(unsigned int tex, float aspect) {
    if (!tex || aspect <= 0.0f) return;
    // Painted straight into the draw list, centered in the menu-bar rect; the layout only
    // sees a zero-HEIGHT spacer for the width. An ImGui::Image item here would instead set
    // the bar's line height from the image's own y, and every menu after it drops lower —
    // the item path and the text path disagree about where a line starts.
    ImDrawList* dl = ImGui::GetWindowDrawList();
    // BeginMenuBar's clip rect IS the bar; center in that rather than trusting window
    // fields, whose height the pushed menu FramePadding does not reach.
    ImVec2 cmin = dl->GetClipRectMin();
    ImVec2 cmax = dl->GetClipRectMax();
    float h = ImGui::GetFontSize();
    float w = h * aspect;
    ImVec2 p = ImGui::GetCursorScreenPos();
    float y = cmin.y + (cmax.y - cmin.y - h) * 0.5f;
    dl->AddImage((ImTextureID)(intptr_t)tex, ImVec2(p.x, y), ImVec2(p.x + w, y + h),
                 ImVec2(0, 0), ImVec2(1, 1), ImGui::GetColorU32(ImGuiCol_Text));
    ImGui::Dummy(ImVec2(w, 0.0f));
}

// Frames to keep rendering at full rate after the last UI activity, so imgui animations
// (window close, dock reflow, tab/hover fades) play smoothly instead of at the idle wait
// rate. Set in vgui_frame_end when activity is detected; counted down here.
static int g_busy_frames = 0;

int vgui_running() {
    if (glfwWindowShouldClose(g_win)) return 0;
    if (g_event_driven) {
        // Busy (recent input / active item / animation) → ~60fps; truly idle → 0.5s wait.
        if (g_busy_frames > 0) glfwWaitEventsTimeout(1.0/60.0);
        else glfwWaitEventsTimeout(0.5);
    } else {
        glfwPollEvents();
    }
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
    // Keep rendering at full rate for a short burst after any UI activity so imgui's
    // close/reflow/hover animations settle smoothly (otherwise they play at the 0.5s idle
    // rate → a window takes ~1-2s to visibly close). True idle falls back to the cheap wait.
    bool active = io.MouseDown[0] || io.MouseDown[1] || io.MouseDown[2]
        || io.MouseWheel != 0.0f || io.MouseWheelH != 0.0f
        || io.MouseDelta.x != 0.0f || io.MouseDelta.y != 0.0f
        || io.WantTextInput || ImGui::IsAnyItemActive();
    if (active) g_busy_frames = 45;          // ~0.75s of smooth frames after the last input
    else if (g_busy_frames > 0) g_busy_frames--;
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
    // x/y are MAIN-WINDOW-relative: with multi-viewport enabled, ImGui window coords are
    // absolute DESKTOP coords, so a bare (x,y) lands on the primary monitor even when the
    // app runs on another one. Offset by the main viewport pos. (#55 applied this to
    // eval/vgui/vgui_glue.cpp; the libs copy this app actually links never got it — so
    // every floating window regressed to the wrong monitor.)
    // FirstUseEver, NOT Once: Once re-applies on the first Begin of EVERY SESSION and
    // overrides the rect imgui.ini saved, so a persistent window (the floating DBC editor)
    // snapped back to its hardcoded default on every launch. FirstUseEver yields to the ini —
    // the caller's values are only the seed for a window the user has never placed.
    const ImGuiViewport* vp = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(ImVec2(vp->Pos.x + x, vp->Pos.y + y), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(ImVec2(w,h), ImGuiCond_FirstUseEver);
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
// right-click context menu on the LAST-submitted item: returns 1 if open (render menu_items
// then call vgui_end_popup). `id` keeps each row's menu distinct.
int  vgui_begin_popup_context_item(const char* id) { return ImGui::BeginPopupContextItem(id) ? 1 : 0; }
// right-click context menu for the CURRENT WINDOW/child (no prior item needed) — the
// scrollback consoles use it for copy actions. Pair with vgui_end_popup.
int  vgui_begin_popup_context_window() { return ImGui::BeginPopupContextWindow() ? 1 : 0; }
// put text on the OS clipboard (GLFW backend bridges it; WSLg bridges to Windows).
void vgui_clipboard_set(const char* s) { ImGui::SetClipboardText(s); }
void vgui_end_popup() { ImGui::EndPopup(); }
int  vgui_menu_item(const char* label) { return ImGui::MenuItem(label) ? 1 : 0; }
int  vgui_menu_item_check(const char* label, int checked) {
    bool b = checked != 0;
    ImGui::MenuItem(label, nullptr, &b);
    return b ? 1 : 0;
}

// --- more widgets ---
// checkbox square side = FontSize + 2*FramePadding.y; our theme padding (7) makes chunky boxes,
// so shrink just the checkbox's vertical padding for a smaller tick box (keeps the label height).
int  vgui_checkbox(const char* label, int cur) {
    bool b = cur != 0;
    float px = ImGui::GetStyle().FramePadding.x;
    float py = ImGui::GetStyle().FramePadding.y;
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(px, py * 0.4f));
    ImGui::Checkbox(label, &b);
    ImGui::PopStyleVar();
    return b ? 1 : 0;
}
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
        ImPlot::SetupAxes("t (s)", NULL, ImPlotAxisFlags_AutoFit, ImPlotAxisFlags_AutoFit);
        return 1;
    }
    return 0;
}
// plot with a FIXED x (time) window [x_min,x_max] — a scrolling strip chart you watch, rather
// than the whole-history autofit. y still autofits. x_max<=x_min falls back to x-autofit (full).
int vgui_plot_begin_x(const char* title, float height, double x_min, double x_max) {
    if (ImPlot::BeginPlot(title, ImVec2(-1, height))) {
        int xflags = (x_max > x_min) ? ImPlotAxisFlags_None : ImPlotAxisFlags_AutoFit;
        ImPlot::SetupAxes("t (s)", NULL, xflags, ImPlotAxisFlags_AutoFit);
        if (x_max > x_min) ImPlot::SetupAxisLimits(ImAxis_X1, x_min, x_max, ImPlotCond_Always);
        return 1;
    }
    return 0;
}
void vgui_plot_line(const char* name, const float* xs, const float* ys, int n) {
    ImPlot::PlotLine(name, xs, ys, n);
}
// plot with a fixed x-window AND up to 3 real y-axes (each auto-fitting to its own series, so
// signals of different scale keep real values in ONE view). Crosshairs are on. Bind a series
// to an axis with vgui_plot_line_axis; query the cursor with vgui_plot_is_hovered/_mouse_x.
int vgui_plot_begin2(const char* title, float height, double x_min, double x_max, int n_yaxes) {
    if (ImPlot::BeginPlot(title, ImVec2(-1, height), ImPlotFlags_Crosshairs)) {
        int xf = (x_max > x_min) ? ImPlotAxisFlags_None : ImPlotAxisFlags_AutoFit;
        ImPlot::SetupAxis(ImAxis_X1, "t (s)", xf);
        // Y flags are AutoFit and NEVER change from frame to frame — on purpose: SetupAxis only
        // overrides an axis's flags when the passed flags CHANGE (implot tracks PreviousFlags),
        // so the user's right-click menu state (untick Auto-Fit, Min/Max, end locks) persists
        // and the menu is the one owner of manual-axis state. Do not make these flags dynamic.
        // Colour each y-axis's tick labels to match the signal plotted on it. Series auto-take
        // colormap colours in plot order (item i -> colormap[i]) and signal i is bound to axis i,
        // so axis i uses colormap[i]. Push ImPlotCol_AxisText AROUND SetupAxis to style per-axis.
        ImPlot::PushStyleColor(ImPlotCol_AxisText, ImPlot::GetColormapColor(0));
        ImPlot::SetupAxis(ImAxis_Y1, NULL, ImPlotAxisFlags_AutoFit);
        ImPlot::PopStyleColor();
        if (n_yaxes >= 2) {
            ImPlot::PushStyleColor(ImPlotCol_AxisText, ImPlot::GetColormapColor(1));
            ImPlot::SetupAxis(ImAxis_Y2, NULL, ImPlotAxisFlags_AutoFit | ImPlotAxisFlags_Opposite);
            ImPlot::PopStyleColor();
        }
        if (n_yaxes >= 3) {
            ImPlot::PushStyleColor(ImPlotCol_AxisText, ImPlot::GetColormapColor(2));
            ImPlot::SetupAxis(ImAxis_Y3, NULL, ImPlotAxisFlags_AutoFit | ImPlotAxisFlags_Opposite);
            ImPlot::PopStyleColor();
        }
        if (x_max > x_min) ImPlot::SetupAxisLimits(ImAxis_X1, x_min, x_max, ImPlotCond_Always);
        return 1;
    }
    return 0;
}
void vgui_plot_line_axis(const char* name, const float* xs, const float* ys, int n, int axis) {
    int a = axis < 0 ? 0 : (axis > 2 ? 2 : axis);
    ImPlot::SetAxis((ImAxis)(ImAxis_Y1 + a));
    ImPlot::PlotLine(name, xs, ys, n);
}
int vgui_plot_is_hovered() { return ImPlot::IsPlotHovered() ? 1 : 0; }
double vgui_plot_mouse_x() { return ImPlot::GetPlotMousePos().x; }
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
// borderless child filling the remaining content region (the right pane next to the
// full-height activity bar: toolbar on top, dockspace below).
void vgui_child_fill(const char* id) { ImGui::BeginChild(id, ImVec2(0, 0), ImGuiChildFlags_None); }
void vgui_child_end() { ImGui::EndChild(); }

// single-line text input editing buf in place (caller owns a persistent NUL-terminated
// buffer of bufsize). Returns 1 the frame the text changed.
int vgui_input_text(const char* label, char* buf, int bufsize) {
    return ImGui::InputText(label, buf, (size_t)bufsize) ? 1 : 0;
}
// console-style input (the Shell panel): Enter submits (returns 1) and refocuses the field so
// the user keeps typing; Up/Down recall submitted lines (the imgui demo-console pattern --
// history must be edited INSIDE the InputText callback, so it lives here, not in V). One
// fixed-size history: the app has a single console.
#define CONSOLE_HIST 32
static char s_con_hist[CONSOLE_HIST][128];
static int  s_con_n = 0;    // lines stored (grows to CONSOLE_HIST, then the oldest is dropped)
static int  s_con_pos = -1; // -1 = editing a fresh line, else index into s_con_hist
static int console_cb(ImGuiInputTextCallbackData* d) {
    if (d->EventFlag != ImGuiInputTextFlags_CallbackHistory || s_con_n == 0) return 0;
    int prev = s_con_pos;
    if (d->EventKey == ImGuiKey_UpArrow) {
        if (s_con_pos == -1) s_con_pos = s_con_n - 1;
        else if (s_con_pos > 0) s_con_pos--;
    } else if (d->EventKey == ImGuiKey_DownArrow) {
        if (s_con_pos != -1 && ++s_con_pos >= s_con_n) s_con_pos = -1;
    }
    if (prev != s_con_pos) {
        d->DeleteChars(0, d->BufTextLen);
        d->InsertChars(0, s_con_pos == -1 ? "" : s_con_hist[s_con_pos]);
    }
    return 0;
}
int vgui_console_input(const char* label, char* buf, int bufsize) {
    bool enter = ImGui::InputText(label, buf, (size_t)bufsize,
        ImGuiInputTextFlags_EnterReturnsTrue | ImGuiInputTextFlags_CallbackHistory,
        console_cb, NULL);
    if (enter) {
        if (buf[0] && (s_con_n == 0 || strcmp(s_con_hist[s_con_n - 1], buf) != 0)) {
            if (s_con_n == CONSOLE_HIST) { // full: drop the oldest line
                memmove(s_con_hist[0], s_con_hist[1], sizeof(s_con_hist[0]) * (CONSOLE_HIST - 1));
                s_con_n--;
            }
            snprintf(s_con_hist[s_con_n++], sizeof(s_con_hist[0]), "%s", buf);
        }
        s_con_pos = -1;
        ImGui::SetKeyboardFocusHere(-1); // re-grab the field the user just submitted
    }
    return enter ? 1 : 0;
}
// read-only, SELECTABLE console text: an InputTextMultiline sized to its content, so the
// caller's own child does the scrolling (vgui_scroll_bottom keeps working) and the inner
// widget never grows a scrollbar. Native mouse selection + Ctrl+A / Ctrl+C for free.
// Transparent frame so it reads as plain console text, not a text box.
void vgui_console_text(const char* id, const char* text, int len, int nlines) {
    ImGui::PushStyleColor(ImGuiCol_FrameBg, ImVec4(0, 0, 0, 0));
    float h = ImGui::GetTextLineHeight() * (float)(nlines + 1)
            + ImGui::GetStyle().FramePadding.y * 2.0f;
    ImGui::InputTextMultiline(id, (char*)text, (size_t)len + 1, ImVec2(-FLT_MIN, h),
                              ImGuiInputTextFlags_ReadOnly);
    ImGui::PopStyleColor();
}
// EDITABLE multiline text — the project-file editor. Fixed capacity, because ImGui writes
// into the caller's buffer: the caller sizes it with headroom and is told when it is nearly
// full, rather than silently truncating what someone typed.
int vgui_text_edit(const char* id, char* buf, int cap, float h) {
    // NO AllowTabInput: the only caller edits YAML, and a literal tab is rejected outright by
    // the parser ("tabs are not supported for indentation") — so the shortcut guaranteed the
    // very error the editor reports. Tab keeps its normal focus behaviour.
    return ImGui::InputTextMultiline(id, buf, (size_t)cap, ImVec2(-FLT_MIN, h)) ? 1 : 0;
}
// pin the current child's scroll to the bottom (call after emitting console output lines).
void vgui_scroll_bottom(void) { ImGui::SetScrollHereY(1.0f); }

// numeric input editing *v in place (for signal values). Returns 1 when changed.
int vgui_input_double(const char* label, double* v) {
    return ImGui::InputDouble(label, v, 0.0, 0.0, "%.3f") ? 1 : 0;
}
int vgui_input_int(const char* label, int* v) {
    // step=0, step_fast=0 -> no +/- stepper buttons: they clutter every numeric field
    // (id / dlc / cycle / bit positions) and add nothing over typing the value.
    return ImGui::InputInt(label, v, 0, 0) ? 1 : 0;
}
// A thin draggable divider between two side-by-side panes. Place it (with same_line) after the
// left child_end and before the right child. Drag it to grow/shrink the left pane; returns the
// new width, clamped to [min_w, max_w]. The handle is invisible until hovered/active.
// remaining content-region extent in the current window/child — pane-budget arithmetic for
// splitter clamps and fill-minus-N layouts.
float vgui_content_avail_w(void) { return ImGui::GetContentRegionAvail().x; }
float vgui_content_avail_h(void) { return ImGui::GetContentRegionAvail().y; }

int vgui_is_item_deactivated_after_edit(void) {
    return ImGui::IsItemDeactivatedAfterEdit() ? 1 : 0;
}

// ONE splitter body for both axes. The guarantee "neither pane can be squeezed out" is a
// property of the WIDGET, not a discipline for call sites: max is floored at min here, because
// the first horizontal call site re-derived the sibling's clamp and dropped exactly that floor
// — a short pane then inverted the clamp, drove the stored size negative, and the caller's
// "<= 0 means default" seed reset the user's dragged height every frame.
static float splitter_axis(const char* id, float pos, float min_v, float max_v, bool horizontal) {
    if (max_v < min_v) max_v = min_v;
    ImGui::PushStyleColor(ImGuiCol_Button,        ImVec4(0,0,0,0));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImGui::GetStyleColorVec4(ImGuiCol_SeparatorHovered));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive,  ImGui::GetStyleColorVec4(ImGuiCol_SeparatorActive));
    const float grip = 6.0f;
    float span = horizontal ? ImGui::GetContentRegionAvail().x : ImGui::GetContentRegionAvail().y;
    if (span < 1.0f) span = 1.0f;
    ImGui::Button(id, horizontal ? ImVec2(span, grip) : ImVec2(grip, span));
    ImGui::PopStyleColor(3);
    if (ImGui::IsItemHovered() || ImGui::IsItemActive())
        ImGui::SetMouseCursor(horizontal ? ImGuiMouseCursor_ResizeNS : ImGuiMouseCursor_ResizeEW);
    if (ImGui::IsItemActive())
        pos += horizontal ? ImGui::GetIO().MouseDelta.y : ImGui::GetIO().MouseDelta.x;
    if (pos < min_v) pos = min_v;
    if (pos > max_v) pos = max_v;
    return pos;
}

float vgui_splitter_v(const char* id, float w, float min_w, float max_w) {
    return splitter_axis(id, w, min_w, max_w, false);
}

// horizontal counterpart: a draggable divider between two stacked panes; returns the new
// height of the pane ABOVE it.
float vgui_splitter_h(const char* id, float h, float min_h, float max_h) {
    return splitter_axis(id, h, min_h, max_h, true);
}

// progress bar with an overlay label; frac is 0..1.
void vgui_progress(float frac, const char* overlay) {
    ImGui::ProgressBar(frac, ImVec2(-1.0f, 0.0f), overlay);
}
// float slider. Writes through v; returns 1 while the value is being changed. Pair with
// vgui_is_item_deactivated_after_edit to act once, on release, rather than per pixel of drag.
int vgui_slider_f(const char* label, float* v, float min_v, float max_v, const char* fmt) {
    return ImGui::SliderFloat(label, v, min_v, max_v, fmt) ? 1 : 0;
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
// Fixed dark colours for the activity bar so it looks identical in light AND dark themes
// (VS Code keeps its activity bar dark regardless of the editor theme). Push before the
// child, pop after. Inactive buttons blend into the strip; the active one gets the accent.
void vgui_activity_style_push() {
    ImGui::PushStyleColor(ImGuiCol_ChildBg,       ImVec4(0x2b/255.f, 0x2b/255.f, 0x2b/255.f, 1.f));
    ImGui::PushStyleColor(ImGuiCol_Button,        ImVec4(0x2b/255.f, 0x2b/255.f, 0x2b/255.f, 0.f));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0x3a/255.f, 0x3a/255.f, 0x3a/255.f, 1.f));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive,  ImVec4(0x09/255.f, 0x47/255.f, 0x71/255.f, 1.f));
    ImGui::PushStyleColor(ImGuiCol_Text,          ImVec4(0xcf/255.f, 0xcf/255.f, 0xcf/255.f, 1.f));
}
void vgui_activity_style_pop() { ImGui::PopStyleColor(5); }

// collapsible tree node (grouped trace rows). If open, render children then call tree_pop.
int  vgui_tree_node(const char* label) { return ImGui::TreeNode(label) ? 1 : 0; }
int  vgui_tree_node_open(const char* label) { return ImGui::TreeNodeEx(label, ImGuiTreeNodeFlags_DefaultOpen) ? 1 : 0; }
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

// vgui_dock_reset throws the persisted dock layout away; the caller's next dock_root()
// rebuilds the default. Just the RemoveNode: the first version also Add'd and sized a fresh
// node, which dock_root deletes and redoes unread — a fourth copy of that triple, kept in
// sync with the other three by nothing. Windows the layout builder does not name pop out
// floating (their dock ref is cleared); that is what "reset to the DEFAULT layout" means.
void vgui_dock_reset() {
    if (g_dockspace_id == 0) return;
    ImGui::DockBuilderRemoveNode(g_dockspace_id);
}

// Returns 1 if the window is visible (active tab / not collapsed). Callers must skip the
// content when it returns 0 but ALWAYS call vgui_end (imgui pairs Begin/End unconditionally).
int vgui_begin(const char* title) { return ImGui::Begin(title) ? 1 : 0; }
// begin with a close [X] in the title bar. *p_open (1/0) is updated when the user clicks it.
int vgui_begin_closable(const char* title, int* p_open) {
    bool open = *p_open != 0;
    bool vis = ImGui::Begin(title, &open);
    *p_open = open ? 1 : 0;
    return vis ? 1 : 0;
}
void vgui_end() { ImGui::End(); }
// set_item_tooltip attaches a hover tooltip to the PREVIOUS item (call right after it).
void vgui_set_item_tooltip(const char* text) {
    if (ImGui::IsItemHovered(ImGuiHoveredFlags_ForTooltip)) ImGui::SetTooltip("%s", text);
}
// help_marker draws a dim "(?)" that shows `text` (wrapped) on hover — inline field help.
void vgui_help_marker(const char* text) {
    ImGui::TextDisabled("(?)");
    if (ImGui::IsItemHovered(ImGuiHoveredFlags_ForTooltip)) {
        ImGui::BeginTooltip();
        ImGui::PushTextWrapPos(ImGui::GetFontSize() * 30.0f);
        ImGui::TextUnformatted(text);
        ImGui::PopTextWrapPos();
        ImGui::EndTooltip();
    }
}
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
int vgui_is_item_clicked_right() { return ImGui::IsItemClicked(ImGuiMouseButton_Right) ? 1 : 0; }
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

// vgui_combo draws a dropdown of `n` items and returns the selected index (== current if the
// user didn't pick a different one this frame). preview shows the current selection when closed.
int vgui_combo(const char* label, const char** items, int n, int current) {
    int sel = current;
    const char* preview = (current >= 0 && current < n) ? items[current] : "";
    if (ImGui::BeginCombo(label, preview)) {
        for (int i = 0; i < n; i++) {
            bool is_sel = (i == current);
            if (ImGui::Selectable(items[i], is_sel)) sel = i;
            if (is_sel) ImGui::SetItemDefaultFocus();
        }
        ImGui::EndCombo();
    }
    return sel;
}

// true while a text field is focused / imgui wants the keyboard — callers use this to suppress
// their own single-key shortcuts so typing in an input box doesn't trigger them.
int vgui_want_text_input() { return ImGui::GetIO().WantTextInput ? 1 : 0; }
// Is any widget holding the keyboard right now? WantTextInput is set only for EDITABLE inputs
// (imgui_widgets.cpp gates it on !is_readonly), so a read-only console the user has clicked
// into -- which owns ActiveId, and Ctrl+A / Ctrl+C -- does not raise it. Callers that must not
// steal keys from a focused widget need this one as well.
int vgui_any_item_active() { return ImGui::IsAnyItemActive() ? 1 : 0; }

// vgui_key_pressed reports whether the printable key `ch` (A-Z / a-z / 0-9) went down THIS frame
// (no auto-repeat). Used for generator hotkeys. Returns 0 for anything it can't map.
int vgui_key_pressed(int ch) {
    ImGuiKey k = ImGuiKey_None;
    if (ch >= 'a' && ch <= 'z')      k = (ImGuiKey)(ImGuiKey_A + (ch - 'a'));
    else if (ch >= 'A' && ch <= 'Z') k = (ImGuiKey)(ImGuiKey_A + (ch - 'A'));
    else if (ch >= '0' && ch <= '9') k = (ImGuiKey)(ImGuiKey_0 + (ch - '0'));
    else return 0;
    return ImGui::IsKeyPressed(k, false) ? 1 : 0;
}

// snap_to_edge magnetically pulls a marker time `t` to the nearest bar edge (start or end) when
// it's within `px` screen pixels — so measurements land on exact interval boundaries. Returns `t`
// unchanged when nothing is close (free positioning away from edges). Must run inside a plot.
static double snap_to_edge(double t, const VBar* bars, int n_bars, double px) {
    double best = t, best_px = px;
    float tx = ImPlot::PlotToPixels(t, 0.0).x;
    for (int k = 0; k < n_bars; k++) {
        double edges[2] = { (double)bars[k].t0, (double)(bars[k].t0 + bars[k].dur) };
        for (int e = 0; e < 2; e++) {
            double dpx = fabs(ImPlot::PlotToPixels(edges[e], 0.0).x - tx);
            if (dpx < best_px) { best_px = dpx; best = edges[e]; }
        }
    }
    return best;
}

// vgui_swimlane draws a handler/task gantt as an ImPlot plot: X = time (µs), Y = lanes.
// ImPlot gives native pan (drag), zoom (scroll/box), and a time axis for free — replacing
// the hand-rolled zoom buttons + scrollbar. Bars are drawn into the plot's draw list in
// pixel space via PlotToPixels, so they track pan/zoom exactly.
void vgui_swimlane(const char* plot_id, int n_lanes, const char** lane_labels,
                   const VBar* bars, int n_bars,
                   const VLink* links, int n_links, float full_span_us,
                   double* cursor_a, double* cursor_b) {
    // Crosshairs: ImPlot draws the follow-the-mouse crosshair; we add a time tag + hover tooltip
    // and two draggable A/B measurement lines below (all in data space, so pan/zoom-correct).
    ImPlotFlags pf = ImPlotFlags_NoLegend | ImPlotFlags_NoMouseText | ImPlotFlags_Crosshairs;
    if (ImPlot::BeginPlot(plot_id, ImVec2(-1, n_lanes * 26.0f + 40.0f), pf)) {
        // X axis in milliseconds (values are µs, scaled by 1e-3 for tick labels via format)
        ImPlot::SetupAxes("time (us)", nullptr,
            ImPlotAxisFlags_None,
            // lane 0 at top; Lock so pan/zoom act on TIME (x) only, never the lanes (y)
            ImPlotAxisFlags_NoGridLines | ImPlotAxisFlags_Invert | ImPlotAxisFlags_Lock);
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
            /* style 1 = READY (preempted, waiting for the CPU): thin + dim, so the wait is
             * visible without reading as execution. style 0 = running. */
            float ytop = bar.style == 1 ? 0.40f : 0.12f;
            float ybot = bar.style == 1 ? 0.60f : 0.88f;
            ImVec2 p0 = ImPlot::PlotToPixels((double)bar.t0, (double)bar.lane + ytop);
            ImVec2 p1 = ImPlot::PlotToPixels((double)(bar.t0+bar.dur), (double)bar.lane + ybot);
            if (p1.x < p0.x + 1) p1.x = p0.x + 1; // 1px floor
            unsigned int col = bar.style == 1 ? (bar.color & 0x00FFFFFFu) | 0x50000000u : bar.color;
            dl->AddRectFilled(p0, p1, col, 1.5f);
            if (bar.warn) dl->AddRect(p0, p1, IM_COL32(233,60,60,255), 1.5f, 1.5f); // rounding, thickness
            if (bar.preempted && (p1.x - p0.x) >= 3) {
                /* Preemption is an EVENT at the slice's END, not a state of the slice: the thread
                 * ran solidly and was then cut. Hatching the whole body read as "spent the slice
                 * being preempted" (while its FB drew solid above). Mark the CUT instead: a short
                 * torn-edge hatch on the trailing sliver + a bright edge line where it happened. */
                float tail = p1.x - p0.x;
                if (tail > 10.0f) tail = 10.0f;
                for (float hx = p1.x - tail + 3; hx < p1.x; hx += 4)
                    dl->AddLine(ImVec2(hx, p0.y), ImVec2(hx - (p1.y - p0.y) * 0.6f, p1.y), IM_COL32(255,255,255,170), 1.0f);
                dl->AddLine(ImVec2(p1.x, p0.y), ImVec2(p1.x, p1.y), IM_COL32(255,255,255,220), 1.5f);
            }
        }
        /* preemption cut-links: a thin vertical connector at the cut instant, from the victim's
         * lane to the preemptor's — preemption is a RELATION (who took the CPU from whom), and a
         * mark on the victim alone reads as if the victim did something. Dot = the preemptor. */
        for (int k = 0; k < n_links; k++) {
            const VLink& ln = links[k];
            ImVec2 a = ImPlot::PlotToPixels((double)ln.x, (double)ln.lane_from + 0.5);
            ImVec2 b = ImPlot::PlotToPixels((double)ln.x, (double)ln.lane_to + 0.5);
            dl->AddLine(a, b, IM_COL32(255, 200, 90, 140), 1.0f);
            dl->AddCircleFilled(b, 2.5f, IM_COL32(255, 200, 90, 220));
        }
        ImPlot::PopPlotClipRect();

        // --- measurement layer: crosshair time tag, hover tooltip, A/B markers + delta ---
        bool hovered = ImPlot::IsPlotHovered();
        ImPlotPoint mp = ImPlot::GetPlotMousePos();
        ImPlotRect lim = ImPlot::GetPlotLimits();

        // a/b keys drop the respective marker at the crosshair; both are draggable afterwards.
        if (hovered) {
            if (ImGui::IsKeyPressed(ImGuiKey_A, false)) *cursor_a = mp.x;
            if (ImGui::IsKeyPressed(ImGuiKey_B, false)) *cursor_b = mp.x;
        }
        ImVec4 colA = ImVec4(0.35f, 0.85f, 0.45f, 1.0f); // green
        ImVec4 colB = ImVec4(0.35f, 0.72f, 0.98f, 1.0f); // cyan
        ImPlot::DragLineX(1001, cursor_a, colA, 1.5f);
        ImPlot::DragLineX(1002, cursor_b, colB, 1.5f);

        // magnetic snap to bar edges (exact interval/period boundaries); hold Alt to place freely.
        if (!ImGui::GetIO().KeyAlt) {
            *cursor_a = snap_to_edge(*cursor_a, bars, n_bars, 8.0);
            *cursor_b = snap_to_edge(*cursor_b, bars, n_bars, 8.0);
        }

        // shade the measured span and tag A, B, and the delta
        double lo = *cursor_a < *cursor_b ? *cursor_a : *cursor_b;
        double hi = *cursor_a < *cursor_b ? *cursor_b : *cursor_a;
        ImVec2 s0 = ImPlot::PlotToPixels(lo, lim.Y.Min);
        ImVec2 s1 = ImPlot::PlotToPixels(hi, lim.Y.Max);
        dl->AddRectFilled(s0, s1, IM_COL32(120, 160, 220, 26));
        ImPlot::TagX(*cursor_a, colA, "A");
        ImPlot::TagX(*cursor_b, colB, "B");
        double d = hi - lo;
        ImPlot::Annotation((lo + hi) * 0.5, lim.Y.Min, ImVec4(1, 1, 1, 1), ImVec2(0, 2), true,
                           "%.0f us (%.3f ms)", d, d / 1000.0);

        // crosshair time tag + hover-a-bar tooltip
        if (hovered) {
            ImPlot::TagX(mp.x, ImVec4(0.80f, 0.80f, 0.80f, 1.0f), "%.0f", mp.x);
            for (int k = 0; k < n_bars; k++) {
                const VBar& bar = bars[k];
                if (mp.x >= bar.t0 && mp.x <= bar.t0 + bar.dur &&
                    mp.y >= bar.lane + 0.12 && mp.y <= bar.lane + 0.88) {
                    // period = start-to-start of the previous bar on this same lane, if any.
                    double prev_t0 = -1.0;
                    for (int j = 0; j < n_bars; j++)
                        if (bars[j].lane == bar.lane && bars[j].t0 < bar.t0 && bars[j].t0 > prev_t0)
                            prev_t0 = bars[j].t0;
                    ImGui::BeginTooltip();
                    ImGui::TextUnformatted(bar.lane < n_lanes ? lane_labels[bar.lane] : "?");
                    ImGui::Text("start %.0f us   dur %.0f us", (double)bar.t0, (double)bar.dur);
                    if (prev_t0 >= 0.0)
                        ImGui::Text("period (since prev on lane): %.0f us", (double)bar.t0 - prev_t0);
                    if (bar.warn) ImGui::TextColored(ImVec4(0.95f, 0.35f, 0.35f, 1.0f), "OVERRAN (trigger)");
                    ImGui::TextDisabled("m = measure this bar (A=start, B=end)");
                    ImGui::EndTooltip();
                    // m measures this bar's exact span into the A/B markers.
                    if (ImGui::IsKeyPressed(ImGuiKey_M, false)) {
                        *cursor_a = bar.t0;
                        *cursor_b = bar.t0 + bar.dur;
                    }
                    break;
                }
            }
        }
        ImPlot::EndPlot();
    }
}

} // extern "C"
