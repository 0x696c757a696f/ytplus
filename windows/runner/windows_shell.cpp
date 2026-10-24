#include "windows_shell.h"

// C++/WinRT first: it wants to see <windows.h> and <unknwn.h> before the rest.
#include <unknwn.h>
#include <dwrite.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>

#include <systemmediatransportcontrolsinterop.h>

#include <shellapi.h>

#include <chrono>
#include <set>
#include <string>

#include <flutter/standard_method_codec.h>

#include "resource.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
namespace media = winrt::Windows::Media;

constexpr UINT kMediaButtonMessage = WM_APP + 1;  // wparam: MediaButton, lparam: milliseconds for a seek
constexpr UINT kTrayMessage = WM_APP + 2;         // lparam: the mouse message on the tray icon
constexpr UINT kTrayIconId = 1;

enum MediaButton : WPARAM { kPlay = 1, kPause, kNext, kPrevious, kStop, kSeek };
enum TrayCommand : UINT { kTrayShow = 1, kTrayPlayPause, kTrayNext, kTrayExit };

// Dart sends UTF-8; the tray and the overlay want UTF-16.
std::wstring Widen(const std::string& text) {
  if (text.empty()) return L"";
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring wide(size, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), wide.data(), size);
  return wide;
}

std::string Narrow(const std::wstring& text) {
  if (text.empty()) return "";
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string narrow(size, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), narrow.data(), size, nullptr, nullptr);
  return narrow;
}

// DirectWrite is the same collection Flutter asks Windows to resolve. It gives
// family names rather than registry file names, so a returned value can be
// supplied directly to ThemeData.fontFamily.
flutter::EncodableList SystemFontFamilies() {
  IDWriteFactory* factory = nullptr;
  if (FAILED(::DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(&factory)))) return {};
  IDWriteFontCollection* collection = nullptr;
  if (FAILED(factory->GetSystemFontCollection(&collection))) {
    factory->Release();
    return {};
  }
  std::set<std::string> families;
  for (UINT32 i = 0; i < collection->GetFontFamilyCount(); ++i) {
    IDWriteFontFamily* family = nullptr;
    if (FAILED(collection->GetFontFamily(i, &family))) continue;
    IDWriteLocalizedStrings* names = nullptr;
    if (SUCCEEDED(family->GetFamilyNames(&names))) {
      UINT32 index = 0;
      BOOL found = FALSE;
      names->FindLocaleName(L"zh-cn", &index, &found);
      if (!found) names->FindLocaleName(L"en-us", &index, &found);
      if (!found) index = 0;
      UINT32 length = 0;
      if (SUCCEEDED(names->GetStringLength(index, &length)) && length > 0) {
        std::wstring name(length + 1, L'\0');
        if (SUCCEEDED(names->GetString(index, name.data(), length + 1))) {
          name.resize(length);
          families.insert(Narrow(name));
        }
      }
      names->Release();
    }
    family->Release();
  }
  collection->Release();
  factory->Release();
  flutter::EncodableList result;
  for (const auto& family : families) result.emplace_back(family);
  return result;
}

const EncodableValue* Find(const EncodableValue* arguments, const char* key) {
  const auto* map = arguments ? std::get_if<EncodableMap>(arguments) : nullptr;
  if (!map) return nullptr;
  const auto it = map->find(EncodableValue(key));
  return it == map->end() ? nullptr : &it->second;
}

std::string StringArg(const EncodableValue* arguments, const char* key) {
  const auto* value = Find(arguments, key);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : std::string();
}

bool BoolArg(const EncodableValue* arguments, const char* key) {
  const auto* value = Find(arguments, key);
  const auto* flag = value ? std::get_if<bool>(value) : nullptr;
  return flag && *flag;
}

int64_t IntArg(const EncodableValue* arguments, const char* key) {
  const auto* value = Find(arguments, key);
  if (!value) return 0;
  if (const auto* narrow = std::get_if<int32_t>(value)) return *narrow;
  if (const auto* wide = std::get_if<int64_t>(value)) return *wide;
  return 0;
}

}  // namespace

// The media overlay. Its events arrive on a thread-pool thread, so they only
// post a message to the window, which Dart is told about on the UI thread.
struct WindowsShell::Media {
  media::SystemMediaTransportControls controls{nullptr};
  winrt::event_token button_token, seek_token;

  explicit Media(HWND window) {
    auto interop = winrt::get_activation_factory<media::SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop->GetForWindow(window, winrt::guid_of<media::SystemMediaTransportControls>(),
                                               winrt::put_abi(controls)));
    controls.IsEnabled(false);
    controls.IsPlayEnabled(true);
    controls.IsPauseEnabled(true);
    controls.IsStopEnabled(false);
    controls.IsNextEnabled(false);
    controls.IsPreviousEnabled(false);
    button_token = controls.ButtonPressed([window](auto const&, media::SystemMediaTransportControlsButtonPressedEventArgs const& args) {
      WPARAM button = 0;
      switch (args.Button()) {
        case media::SystemMediaTransportControlsButton::Play: button = kPlay; break;
        case media::SystemMediaTransportControlsButton::Pause: button = kPause; break;
        case media::SystemMediaTransportControlsButton::Next: button = kNext; break;
        case media::SystemMediaTransportControlsButton::Previous: button = kPrevious; break;
        case media::SystemMediaTransportControlsButton::Stop: button = kStop; break;
        default: return;
      }
      ::PostMessage(window, kMediaButtonMessage, button, 0);
    });
    seek_token = controls.PlaybackPositionChangeRequested([window](auto const&, media::PlaybackPositionChangeRequestedEventArgs const& args) {
      const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(args.RequestedPlaybackPosition()).count();
      ::PostMessage(window, kMediaButtonMessage, kSeek, static_cast<LPARAM>(ms));
    });
  }

  ~Media() {
    try {
      controls.ButtonPressed(button_token);
      controls.PlaybackPositionChangeRequested(seek_token);
      controls.IsEnabled(false);
    } catch (...) {
    }
  }

  void SetMetadata(const std::string& title, const std::string& artist, const std::string& thumbnail) {
    auto updater = controls.DisplayUpdater();
    updater.Type(media::MediaPlaybackType::Music);
    updater.MusicProperties().Title(winrt::to_hstring(title));
    updater.MusicProperties().Artist(winrt::to_hstring(artist));
    try {
      using winrt::Windows::Storage::Streams::RandomAccessStreamReference;
      if (thumbnail.empty()) {
        updater.Thumbnail(nullptr);
      } else {
        updater.Thumbnail(RandomAccessStreamReference::CreateFromUri(winrt::Windows::Foundation::Uri(winrt::to_hstring(thumbnail))));
      }
    } catch (...) {
      // A bad address only loses the picture.
    }
    updater.Update();
    controls.IsEnabled(true);
  }

  void SetStatus(const std::string& status) {
    if (status == "playing") {
      controls.PlaybackStatus(media::MediaPlaybackStatus::Playing);
    } else if (status == "paused") {
      controls.PlaybackStatus(media::MediaPlaybackStatus::Paused);
    } else {
      controls.PlaybackStatus(media::MediaPlaybackStatus::Closed);
      controls.IsEnabled(false);
      return;
    }
    controls.IsEnabled(true);
  }

  void SetTimeline(int64_t position_ms, int64_t duration_ms) {
    using std::chrono::milliseconds;
    media::SystemMediaTransportControlsTimelineProperties timeline;
    timeline.StartTime(milliseconds(0));
    timeline.MinSeekTime(milliseconds(0));
    timeline.Position(milliseconds(position_ms));
    timeline.MaxSeekTime(milliseconds(duration_ms));
    timeline.EndTime(milliseconds(duration_ms));
    controls.UpdateTimelineProperties(timeline);
  }

  void SetButtons(bool next, bool previous) {
    controls.IsNextEnabled(next);
    controls.IsPreviousEnabled(previous);
  }
};

WindowsShell::WindowsShell(HWND window, flutter::BinaryMessenger* messenger) : window_(window) {
  try {
    media_ = std::make_unique<Media>(window);
  } catch (...) {
    media_.reset();  // Without the overlay everything else still works.
  }
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "lumtub/windows_shell", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { HandleCall(call, std::move(result)); });
}

WindowsShell::~WindowsShell() {
  channel_->SetMethodCallHandler(nullptr);
  RemoveTrayIcon();
}

void WindowsShell::Send(const char* method, EncodableValue argument) {
  channel_->InvokeMethod(method, std::make_unique<EncodableValue>(std::move(argument)));
}

void WindowsShell::HandleCall(const flutter::MethodCall<EncodableValue>& call,
                              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  const EncodableValue* args = call.arguments();
  try {
    if (method == "listSystemFonts") {
      result->Success(EncodableValue(SystemFontFamilies()));
      return;
    } else if (method == "setTray") {
      close_to_tray_ = BoolArg(args, "enabled");
      show_label_ = Widen(StringArg(args, "show"));
      play_pause_label_ = Widen(StringArg(args, "playPause"));
      next_label_ = Widen(StringArg(args, "next"));
      exit_label_ = Widen(StringArg(args, "exit"));
      if (!close_to_tray_) RemoveTrayIcon();
    } else if (media_ && method == "setMetadata") {
      media_->SetMetadata(StringArg(args, "title"), StringArg(args, "artist"), StringArg(args, "thumbnail"));
    } else if (media_ && method == "setStatus") {
      media_->SetStatus(args ? std::get<std::string>(*args) : std::string());
    } else if (media_ && method == "setTimeline") {
      media_->SetTimeline(IntArg(args, "position"), IntArg(args, "duration"));
    } else if (media_ && method == "setButtons") {
      media_->SetButtons(BoolArg(args, "next"), BoolArg(args, "previous"));
    } else if (!media_ && method != "setTray") {
      // No overlay on this system; nothing to do.
    } else {
      result->NotImplemented();
      return;
    }
  } catch (const winrt::hresult_error&) {
    // The overlay is a convenience; a failed update is not worth reporting.
  } catch (const std::exception&) {
  }
  result->Success();
}

bool WindowsShell::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam, LRESULT* result) {
  switch (message) {
    case WM_CLOSE:
      if (!close_to_tray_) return false;
      HideToTray();
      *result = 0;
      return true;
    case kMediaButtonMessage:
      switch (wparam) {
        case kPlay: Send("button", EncodableValue("play")); break;
        case kPause: Send("button", EncodableValue("pause")); break;
        case kNext: Send("button", EncodableValue("next")); break;
        case kPrevious: Send("button", EncodableValue("previous")); break;
        case kStop: Send("button", EncodableValue("stop")); break;
        case kSeek: Send("seek", EncodableValue(static_cast<int64_t>(lparam))); break;
      }
      *result = 0;
      return true;
    case kTrayMessage:
      if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) {
        ShowFromTray();
      } else if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
        ShowTrayMenu();
      }
      *result = 0;
      return true;
  }
  return false;
}

void WindowsShell::HideToTray() {
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = window_;
  icon.uID = kTrayIconId;
  icon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = ::LoadIcon(::GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(icon.szTip, L"Lumtub");
  if (!tray_icon_ && !::Shell_NotifyIconW(NIM_ADD, &icon)) return;  // No icon to bring it back: stay open.
  tray_icon_ = true;
  ::ShowWindow(window_, SW_HIDE);
}

void WindowsShell::RemoveTrayIcon() {
  if (!tray_icon_) return;
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = window_;
  icon.uID = kTrayIconId;
  ::Shell_NotifyIconW(NIM_DELETE, &icon);
  tray_icon_ = false;
}

void WindowsShell::ShowFromTray() {
  RemoveTrayIcon();
  ::ShowWindow(window_, ::IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(window_);
}

void WindowsShell::ShowTrayMenu() {
  HMENU menu = ::CreatePopupMenu();
  ::AppendMenuW(menu, MF_STRING, kTrayShow, show_label_.c_str());
  ::AppendMenuW(menu, MF_STRING, kTrayPlayPause, play_pause_label_.c_str());
  ::AppendMenuW(menu, MF_STRING, kTrayNext, next_label_.c_str());
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kTrayExit, exit_label_.c_str());
  POINT cursor;
  ::GetCursorPos(&cursor);
  // The menu closes on a click elsewhere only if its owner is foreground.
  ::SetForegroundWindow(window_);
  const UINT command = ::TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, cursor.x, cursor.y, 0, window_, nullptr);
  ::PostMessage(window_, WM_NULL, 0, 0);
  ::DestroyMenu(menu);
  switch (command) {
    case kTrayShow: ShowFromTray(); break;
    case kTrayPlayPause: Send("button", EncodableValue("playpause")); break;
    case kTrayNext: Send("button", EncodableValue("next")); break;
    case kTrayExit:
      // The normal close path, so Dart saves progress and releases the player.
      close_to_tray_ = false;
      RemoveTrayIcon();
      ::PostMessage(window_, WM_CLOSE, 0, 0);
      break;
  }
}
