#include "flutter_window.h"

#include <shlobj.h>

#include <filesystem>
#include <fstream>
#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// %LOCALAPPDATA%\Sonar\window.dat: the window's last placement.
std::filesystem::path PlacementFile() {
  PWSTR folder = nullptr;
  std::filesystem::path path;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &folder))) {
    path = std::filesystem::path(folder) / L"Sonar" / L"window.dat";
  }
  CoTaskMemFree(folder);
  return path;
}

// Smallest window that still fits the phone layout.
constexpr int kMinWidth = 400;
constexpr int kMinHeight = 600;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

void FlutterWindow::RestorePlacement() {
  const auto file = PlacementFile();
  if (file.empty()) return;
  std::ifstream in(file, std::ios::binary);
  WINDOWPLACEMENT placement{};
  if (!in.read(reinterpret_cast<char*>(&placement), sizeof(placement)) ||
      placement.length != sizeof(placement)) {
    return;
  }
  // Skip it if that spot is no longer on any monitor (one was unplugged).
  if (MonitorFromRect(&placement.rcNormalPosition, MONITOR_DEFAULTTONULL) == nullptr) {
    return;
  }
  const bool maximized = placement.showCmd == SW_SHOWMAXIMIZED;
  placement.showCmd = SW_HIDE;  // Shown with the first frame.
  SetWindowPlacement(GetHandle(), &placement);
  show_command_ = maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
}

void FlutterWindow::SavePlacement() {
  const auto file = PlacementFile();
  if (file.empty()) return;
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!GetWindowPlacement(GetHandle(), &placement)) return;
  std::error_code ignored;
  std::filesystem::create_directories(file.parent_path(), ignored);
  std::ofstream out(file, std::ios::binary | std::ios::trunc);
  out.write(reinterpret_cast<const char*>(&placement), sizeof(placement));
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_GETMINMAXINFO: {
      const double scale = GetDpiForWindow(hwnd) / 96.0;
      auto info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = static_cast<LONG>(kMinWidth * scale);
      info->ptMinTrackSize.y = static_cast<LONG>(kMinHeight * scale);
      return 0;
    }
    case WM_CLOSE:
      SavePlacement();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
