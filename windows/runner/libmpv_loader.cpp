#include "libmpv_loader.h"

#include "data_root.h"

#include <windows.h>

#include <string>

// media_kit_video_plugin.dll imports libmpv-2.dll by name and is delay-loaded
// (see CMakeLists.txt). Windows reuses a module that is already loaded under
// the same name, so loading an updated copy here makes the plugin and Dart
// share it; otherwise the copy next to the executable is used.
//
// State lives in <DataRoot()>\components\mpv and is written by
// lib/libmpv_updates.dart. All files are UTF-8 text:
//   use.txt        full path of the downloaded libmpv-2.dll to use
//   confirmed.txt  that path, once a video has played with it
//   pending.txt    "<path>\n<state>" while it is unconfirmed; the state is a
//                  launch count, or "playing" while the first video starts
//   failed.txt     paths never to load again, one per line

namespace {

constexpr int kMaxUnconfirmedLaunches = 3;

std::wstring StateDirectory() {
  if (DataRoot().empty()) return L"";
  return DataRoot() + L"\\components\\mpv\\";
}

std::wstring Widen(const std::string& text) {
  if (text.empty()) return L"";
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), size);
  return result;
}

std::string Narrow(const std::wstring& text) {
  if (text.empty()) return "";
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string result(size, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), size, nullptr, nullptr);
  return result;
}

std::wstring ReadText(const std::wstring& path) {
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return L"";
  std::string content;
  char chunk[4096];
  DWORD read = 0;
  while (::ReadFile(file, chunk, sizeof(chunk), &read, nullptr) && read > 0 && content.size() < 65536) {
    content.append(chunk, read);
  }
  ::CloseHandle(file);
  return Widen(content);
}

void WriteText(const std::wstring& path, const std::wstring& text, bool append) {
  HANDLE file = ::CreateFileW(path.c_str(), append ? FILE_APPEND_DATA : GENERIC_WRITE, 0, nullptr,
                              append ? OPEN_ALWAYS : CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  const std::string bytes = Narrow(text);
  DWORD written = 0;
  ::WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr);
  ::CloseHandle(file);
}

std::wstring Trim(const std::wstring& text) {
  const size_t start = text.find_first_not_of(L" \t\r\n");
  if (start == std::wstring::npos) return L"";
  const size_t end = text.find_last_not_of(L" \t\r\n");
  return text.substr(start, end - start + 1);
}

std::wstring FirstLine(const std::wstring& text) { return Trim(text.substr(0, text.find(L'\n'))); }

std::wstring SecondLine(const std::wstring& text) {
  const size_t newline = text.find(L'\n');
  return newline == std::wstring::npos ? L"" : FirstLine(text.substr(newline + 1));
}

bool ListedIn(const std::wstring& list, const std::wstring& path) {
  size_t start = 0;
  while (start <= list.size()) {
    size_t end = list.find(L'\n', start);
    if (end == std::wstring::npos) end = list.size();
    if (::CompareStringOrdinal(Trim(list.substr(start, end - start)).c_str(), -1, path.c_str(), -1, TRUE) == CSTR_EQUAL) return true;
    start = end + 1;
  }
  return false;
}

void MarkFailed(const std::wstring& directory, const std::wstring& path) {
  WriteText(directory + L"failed.txt", path + L"\n", true);
  ::DeleteFileW((directory + L"pending.txt").c_str());
  ::DeleteFileW((directory + L"use.txt").c_str());
}

}  // namespace

void LoadPreferredLibmpv() {
  const std::wstring directory = StateDirectory();
  if (directory.empty()) return;
  const std::wstring path = FirstLine(ReadText(directory + L"use.txt"));
  if (path.empty() || ::GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) return;
  if (ListedIn(ReadText(directory + L"failed.txt"), path)) return;

  const bool confirmed = ::CompareStringOrdinal(FirstLine(ReadText(directory + L"confirmed.txt")).c_str(), -1, path.c_str(), -1, TRUE) == CSTR_EQUAL;
  if (!confirmed) {
    // An earlier launch that crashed while starting a video, or several
    // launches that never played one, mean this copy should not be trusted.
    const std::wstring pending = ReadText(directory + L"pending.txt");
    int launches = 0;
    if (::CompareStringOrdinal(FirstLine(pending).c_str(), -1, path.c_str(), -1, TRUE) == CSTR_EQUAL) {
      const std::wstring state = SecondLine(pending);
      launches = state == L"playing" ? kMaxUnconfirmedLaunches : _wtoi(state.c_str());
    }
    if (launches >= kMaxUnconfirmedLaunches) {
      MarkFailed(directory, path);
      return;
    }
    WriteText(directory + L"pending.txt", path + L"\n" + std::to_wstring(launches + 1) + L"\n", false);
  }

  // LOAD_WITH_ALTERED_SEARCH_PATH resolves the DLL's own dependencies from
  // its folder rather than the executable's.
  if (::LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH) == nullptr) {
    MarkFailed(directory, path);
    return;
  }
  ::SetEnvironmentVariableW(L"LUMTUB_LIBMPV", path.c_str());
}
