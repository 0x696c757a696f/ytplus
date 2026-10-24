#include "data_root.h"

#include <windows.h>

#include <string>

namespace {

std::wstring ExecutableDirectory() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD length = ::GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0) return L"";
    if (length < path.size()) {
      path.resize(length);
      break;
    }
    path.resize(path.size() * 2);
  }
  const size_t slash = path.find_last_of(L"\\/");
  return slash == std::wstring::npos ? L"" : path.substr(0, slash);
}

// Points the libmpv state files, which hold full paths, at [to] after the
// data folder moved from [from].
void RepointLibmpvState(const std::wstring& from, const std::wstring& to) {
  for (const wchar_t* name : {L"use.txt", L"confirmed.txt", L"pending.txt", L"failed.txt"}) {
    const std::wstring path = to + L"\\components\\mpv\\" + name;
    const HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (file == INVALID_HANDLE_VALUE) continue;
    std::string bytes(static_cast<size_t>(::GetFileSize(file, nullptr) & 0xFFFF), '\0');
    DWORD read = 0;
    const bool ok = ::ReadFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &read, nullptr);
    ::CloseHandle(file);
    if (!ok) continue;
    bytes.resize(read);
    const int length = ::MultiByteToWideChar(CP_UTF8, 0, bytes.data(), static_cast<int>(bytes.size()), nullptr, 0);
    std::wstring text(length, L'\0');
    ::MultiByteToWideChar(CP_UTF8, 0, bytes.data(), static_cast<int>(bytes.size()), text.data(), length);
    std::wstring updated;
    size_t start = 0;
    for (size_t found; (found = text.find(from, start)) != std::wstring::npos; start = found + from.size()) {
      updated += text.substr(start, found - start) + to;
    }
    updated += text.substr(start);
    if (updated == text) continue;
    const int size = ::WideCharToMultiByte(CP_UTF8, 0, updated.data(), static_cast<int>(updated.size()), nullptr, 0, nullptr, nullptr);
    std::string out(size, '\0');
    ::WideCharToMultiByte(CP_UTF8, 0, updated.data(), static_cast<int>(updated.size()), out.data(), size, nullptr, nullptr);
    const HANDLE target = ::CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (target == INVALID_HANDLE_VALUE) continue;
    DWORD written = 0;
    ::WriteFile(target, out.data(), static_cast<DWORD>(out.size()), &written, nullptr);
    ::CloseHandle(target);
  }
}

bool Exists(const std::wstring& path) {
  return ::GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

// Whether files can be created in [directory], creating it first.
bool Writable(const std::wstring& directory) {
  ::CreateDirectoryW(directory.c_str(), nullptr);
  const std::wstring probe = directory + L"\\.write-test";
  const HANDLE file = ::CreateFileW(probe.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                                    FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  ::CloseHandle(file);
  return true;
}

std::wstring LocalAppDataRoot() {
  const DWORD required = ::GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
  if (required == 0) return L"";
  std::wstring value(required, L'\0');
  const DWORD length = ::GetEnvironmentVariableW(L"LOCALAPPDATA", value.data(), required);
  if (length == 0 || length >= required) return L"";
  value.resize(length);
  return value + L"\\Lumtub";
}

std::wstring FindDataRoot() {
  const std::wstring executable = ExecutableDirectory();
  if (!executable.empty() && Exists(executable + L"\\portable.txt")) {
    const std::wstring portable = executable + L"\\userdata";
    if (Writable(portable)) return portable;
  }
  const std::wstring local = LocalAppDataRoot();
  if (local.empty()) return local;
  // Before the rename the folder was called YTPlus; keep using its data.
  const std::wstring previous = local.substr(0, local.find_last_of(L'\\') + 1) + L"YTPlus";
  if (!Exists(local) && Exists(previous) && ::MoveFileExW(previous.c_str(), local.c_str(), 0)) {
    RepointLibmpvState(previous, local);
  }
  ::CreateDirectoryW(local.c_str(), nullptr);
  return local;
}

}  // namespace

const std::wstring& DataRoot() {
  static const std::wstring root = [] {
    std::wstring found = FindDataRoot();
    if (!found.empty()) ::SetEnvironmentVariableW(L"LUMTUB_HOME", found.c_str());
    return found;
  }();
  return root;
}
