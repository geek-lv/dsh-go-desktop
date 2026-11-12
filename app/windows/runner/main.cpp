#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // DSH: unchanged from the official template. The window is centered by
  // Win32Window::Create() (see win32_window.cpp), so |origin| only picks the
  // monitor the window opens on.
  Win32Window::Point origin(10, 10);
  // DSH: initial window size in logical pixels (Win32Window::Create() scales it
  // by the target monitor's DPI). Matches the macOS runner's initial content
  // size of 1180x820 (macos/Runner/MainFlutterWindow.swift).
  // NOTE: 需与官方模板核对 — 官方模板为 size(1280, 720)，此处按 macOS 版改为
  // 1180x820。另外 Win32 的 CreateWindow 宽高含边框/标题栏，而 macOS 的
  // setContentSize 只算内容区，两者语义略有差异。
  Win32Window::Size size(1180, 820);
  // DSH: minimum window size in logical pixels, matching the macOS runner's
  // NSWindow.minSize of 860x620.
  // NOTE: 需与官方模板核对 — 官方模板没有最小尺寸限制，SetMinimumSize 是
  // DSH 新增的 API（见 win32_window.h）。
  window.SetMinimumSize(860, 620);
  // DSH: window title. The macOS runner uses "DSH Go Mac"; Windows uses the
  // platform-matching title below instead of the template's project name.
  // NOTE: 需与官方模板核对 — 官方模板为 `window.Create(L"{{projectName}}", ...)`，
  // 即 L"dsh_app"。
  if (!window.Create(L"DSH Go Windows", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
