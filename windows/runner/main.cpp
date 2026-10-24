#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>
#include <dbghelp.h>

#include <algorithm>
#include <string>

#include "data_root.h"
#include "flutter_window.h"
#include "libmpv_loader.h"
#include "utils.h"
#include "window_placement.h"

namespace {

std::wstring CrashLogDirectory() {
  if (DataRoot().empty()) return L"";
  const std::wstring logs = DataRoot() + L"\\logs";
  ::CreateDirectoryW(logs.c_str(), nullptr);
  return logs;
}

LONG WINAPI WriteCrashDump(EXCEPTION_POINTERS* exception) {
  const std::wstring logs = CrashLogDirectory();
  if (logs.empty()) return EXCEPTION_CONTINUE_SEARCH;

  SYSTEMTIME now{};
  ::GetLocalTime(&now);
  wchar_t name[96]{};
  swprintf_s(name, _countof(name), L"\\lumtub-crash-%04u%02u%02u-%02u%02u%02u.dmp",
             now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
             now.wSecond);
  const HANDLE file = ::CreateFileW((logs + name).c_str(), GENERIC_WRITE, 0,
                                    nullptr, CREATE_ALWAYS,
                                    FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return EXCEPTION_CONTINUE_SEARCH;

  MINIDUMP_EXCEPTION_INFORMATION details{};
  details.ThreadId = ::GetCurrentThreadId();
  details.ExceptionPointers = exception;
  details.ClientPointers = FALSE;
  ::MiniDumpWriteDump(
      ::GetCurrentProcess(), ::GetCurrentProcessId(), file,
      static_cast<MINIDUMP_TYPE>(MiniDumpNormal | MiniDumpWithThreadInfo),
      &details, nullptr, nullptr);
  ::CloseHandle(file);
  return EXCEPTION_CONTINUE_SEARCH;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Dart errors are logged in main.dart. This catches process-level failures
  // from the Windows runner, libmpv, ANGLE, or a graphics driver and keeps a
  // small stack dump beside the normal app logs for the next diagnosis.
  ::SetUnhandledExceptionFilter(WriteCrashDump);

  // Before anything reads or writes its files: the portable package keeps
  // them next to the executable.
  DataRoot();

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Before the engine starts and plugins load.
  LoadPreferredLibmpv();

  flutter::DartProject project(L"data");

  // As PiliNara does: with Impeller, media_kit's video texture flashes black
  // on some GPUs (flutter/flutter#188635, #191050, #191069).
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Open centred on the primary monitor's work area, in logical pixels.
  RECT work_area{};
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0);
  const double scale_factor =
      FlutterDesktopGetDpiForMonitor(
          ::MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY)) / 96.0;
  const int work_width = static_cast<int>((work_area.right - work_area.left) / scale_factor);
  const int work_height = static_cast<int>((work_area.bottom - work_area.top) / scale_factor);
  const int width = std::min(1280, std::max(work_width - 40, 640));
  const int height = std::min(800, std::max(work_height - 40, 480));
  const int left = static_cast<int>(work_area.left / scale_factor) + std::max((work_width - width) / 2, 0);
  const int top = static_cast<int>(work_area.top / scale_factor) + std::max((work_height - height) / 2, 0);
  Win32Window::Point origin(static_cast<unsigned int>(left), static_cast<unsigned int>(top));
  Win32Window::Size size(static_cast<unsigned int>(width), static_cast<unsigned int>(height));
  if (!window.Create(L"Lumtub", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetStartMaximized(RestoreWindowPlacement(window.GetHandle()));
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
