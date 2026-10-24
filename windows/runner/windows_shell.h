#ifndef RUNNER_WINDOWS_SHELL_H_
#define RUNNER_WINDOWS_SHELL_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

// The app's ties to the Windows shell, driven from Dart over the
// "lumtub/windows_shell" method channel (lib/windows_shell.dart): the media
// overlay (System Media Transport Controls) with the media keys, and an
// optional tray icon the close button hides the window to.
class WindowsShell {
 public:
  WindowsShell(HWND window, flutter::BinaryMessenger* messenger);
  ~WindowsShell();

  // Handles the shell's window messages (before Flutter sees them); returns
  // true, with the result in |result|, when it did.
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam, LRESULT* result);

 private:
  struct Media;  // The C++/WinRT part, kept out of this header.

  void HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Send(const char* method, flutter::EncodableValue argument);
  void ShowFromTray();
  void HideToTray();
  void ShowTrayMenu();
  void RemoveTrayIcon();

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<Media> media_;
  bool close_to_tray_ = false;
  bool tray_icon_ = false;
  std::wstring show_label_ = L"Show window", play_pause_label_ = L"Play/Pause",
               next_label_ = L"Next", exit_label_ = L"Exit";
};

#endif  // RUNNER_WINDOWS_SHELL_H_
