#include "flutter_window.h"

#include <cmath>
#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "window_placement.h"

namespace {

// The video's width over height while the picture-in-picture window
// (lib/app_window.dart) is shown, otherwise 0. The window property holds the
// ratio times 1000.
double PictureInPictureAspect(HWND window) {
  return reinterpret_cast<uintptr_t>(::GetProp(window, L"LumtubPictureInPicture")) / 1000.0;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

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
  shell_ = std::make_unique<WindowsShell>(GetHandle(), flutter_controller_->engine()->messenger());
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
  shell_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // The close button may hide to the tray, so this comes before Flutter's
  // own handling of WM_CLOSE (which asks Dart whether to exit).
  LRESULT shell_result = 0;
  if (shell_ && shell_->HandleMessage(message, wparam, lparam, &shell_result)) {
    return shell_result;
  }

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
    // Picture in picture may be small, and keeps the video's ratio.
    case WM_GETMINMAXINFO: {
      if (PictureInPictureAspect(hwnd) <= 0) break;
      auto info = reinterpret_cast<MINMAXINFO*>(lparam);
      const double scale = ::GetDpiForWindow(hwnd) / 96.0;
      info->ptMinTrackSize.x = static_cast<LONG>(160 * scale);
      info->ptMinTrackSize.y = static_cast<LONG>(90 * scale);
      return 0;
    }
    // Picture in picture has no frame at all: the client area covers the
    // whole window, and its edges still resize it.
    case WM_NCCALCSIZE:
      if (wparam && PictureInPictureAspect(hwnd) > 0) return 0;
      break;
    case WM_NCHITTEST: {
      if (PictureInPictureAspect(hwnd) <= 0) break;
      RECT rect{};
      ::GetWindowRect(hwnd, &rect);
      const LONG x = static_cast<short>(LOWORD(lparam));
      const LONG y = static_cast<short>(HIWORD(lparam));
      const LONG edge = std::lround(6 * ::GetDpiForWindow(hwnd) / 96.0);
      const bool left = x < rect.left + edge, right = x >= rect.right - edge;
      const bool top = y < rect.top + edge, bottom = y >= rect.bottom - edge;
      if (top && left) return HTTOPLEFT;
      if (top && right) return HTTOPRIGHT;
      if (bottom && left) return HTBOTTOMLEFT;
      if (bottom && right) return HTBOTTOMRIGHT;
      if (left) return HTLEFT;
      if (right) return HTRIGHT;
      if (top) return HTTOP;
      if (bottom) return HTBOTTOM;
      return HTCLIENT;
    }
    case WM_SIZING: {
      const double aspect = PictureInPictureAspect(hwnd);
      if (aspect <= 0) break;
      RECT window{}, client{};
      ::GetWindowRect(hwnd, &window);
      ::GetClientRect(hwnd, &client);
      const LONG extra_w = (window.right - window.left) - client.right;
      const LONG extra_h = (window.bottom - window.top) - client.bottom;
      auto rect = reinterpret_cast<RECT*>(lparam);
      const LONG width = rect->right - rect->left - extra_w;
      const LONG height = rect->bottom - rect->top - extra_h;
      switch (wparam) {
        case WMSZ_LEFT:
        case WMSZ_RIGHT:
          rect->bottom = rect->top + extra_h + std::lround(width / aspect);
          break;
        case WMSZ_TOP:
        case WMSZ_BOTTOM:
          rect->right = rect->left + extra_w + std::lround(height * aspect);
          break;
        case WMSZ_TOPLEFT:
        case WMSZ_TOPRIGHT:
          rect->top = rect->bottom - extra_h - std::lround(width / aspect);
          break;
        default:
          rect->bottom = rect->top + extra_h + std::lround(width / aspect);
      }
      return TRUE;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_CLOSE:
      SaveWindowPlacement(hwnd);
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
