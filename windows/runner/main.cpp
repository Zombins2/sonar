#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// One Sonar per Windows login: a second launch brings the open window to the
// front and quits. Debug builds (flutter run, tests) skip this so they can
// run beside the installed app.
bool AnotherSonarIsOpen() {
#ifdef NDEBUG
  // Held until this process exits; Windows releases it even after a crash.
  ::CreateMutexW(nullptr, FALSE, L"Local\\SonarPlayerSingleInstance");
  if (::GetLastError() != ERROR_ALREADY_EXISTS) return false;
  if (HWND open = ::FindWindowW(L"SONAR_PLAYER_WINDOW", nullptr)) {
    if (::IsIconic(open)) ::ShowWindow(open, SW_RESTORE);
    ::ShowWindow(open, SW_SHOW);
    ::SetForegroundWindow(open);
  }
  return true;
#else
  return false;
#endif
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (AnotherSonarIsOpen()) return EXIT_SUCCESS;

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
  Win32Window::Point origin(80, 60);
  Win32Window::Size size(1280, 800);
  if (!window.Create(L"Sonar", origin, size)) {
    return EXIT_FAILURE;
  }
  // Back where it was last time (size, position, maximised).
  window.RestorePlacement();
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
