import 'dart:ffi';
import 'dart:math';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The picture-in-picture window's ratio for a video [aspect] (width over
/// height): 16:9 when unknown, and never extreme.
double pipAspectOf(double aspect) => aspect.isFinite && aspect > 0 ? aspect.clamp(0.4, 3.0) : 16 / 9;

/// The picture-in-picture picture's size in logical pixels: [shortSide] on
/// its short side, the other side from [aspect] (as PiliNara's 280).
({double width, double height}) pipSizeFor(double aspect, {double shortSide = 280}) {
  final a = pipAspectOf(aspect);
  return a >= 1 ? (width: shortSide * a, height: shortSide) : (width: shortSide, height: shortSide / a);
}

/// The main window's always-on-top state and the picture-in-picture window,
/// through user32 directly: Flutter's Windows embedder has no API for
/// either, and a plugin for a few calls is more than they need.
/// Picture in picture follows PiliNara's desktop one (GPLv3,
/// lib/plugin/pl_player/controller.dart): 280 on the short side, always on
/// top, the ratio kept, the last place remembered.
class AppWindow {
  AppWindow._();

  static final _user32 = Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;
  static final _kernel32 = Platform.isWindows ? DynamicLibrary.open('kernel32.dll') : null;
  static final _dwmapi = Platform.isWindows ? DynamicLibrary.open('dwmapi.dll') : null;
  static final _dwmSetWindowAttribute = _dwmapi?.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<Uint32>, Uint32), int Function(int, int, Pointer<Uint32>, int)>('DwmSetWindowAttribute');

  /// Windows 11 draws a thin border around every window; picture in picture
  /// has none. Ignored on Windows 10, which has no such border.
  static void _setBorder(int window, {required bool visible}) {
    final color = calloc<Uint32>()..value = visible ? _dwmColorDefault : _dwmColorNone;
    try {
      _dwmSetWindowAttribute?.call(window, _dwmwaBorderColor, color, sizeOf<Uint32>());
    } finally {
      calloc.free(color);
    }
  }

  static const _dwmwaBorderColor = 34, _dwmColorDefault = 0xFFFFFFFF, _dwmColorNone = 0xFFFFFFFE;

  static final _findWindowEx = _user32?.lookupFunction<IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>), int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
  static final _getWindowThreadProcessId = _user32?.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
  static final _getCurrentProcessId = _kernel32?.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
  static final _setWindowPos = _user32?.lookupFunction<Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32), int Function(int, int, int, int, int, int, int)>('SetWindowPos');
  static final _getWindowRect = _user32?.lookupFunction<Int32 Function(IntPtr, Pointer<_Rect>), int Function(int, Pointer<_Rect>)>('GetWindowRect');
  static final _isZoomed = _user32?.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsZoomed');
  static final _showWindow = _user32?.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');
  static final _monitorFromWindow = _user32?.lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>('MonitorFromWindow');
  static final _getMonitorInfo = _user32?.lookupFunction<Int32 Function(IntPtr, Pointer<_MonitorInfo>), int Function(int, Pointer<_MonitorInfo>)>('GetMonitorInfoW');
  static final _getDpiForWindow = _user32?.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('GetDpiForWindow');
  static final _setProp = _user32?.lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, IntPtr), int Function(int, Pointer<Utf16>, int)>('SetPropW');
  static final _getClientRect = _user32?.lookupFunction<Int32 Function(IntPtr, Pointer<_Rect>), int Function(int, Pointer<_Rect>)>('GetClientRect');
  static final _getWindowLongPtr = _user32?.lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>('GetWindowLongPtrW');
  static final _setWindowLongPtr = _user32?.lookupFunction<IntPtr Function(IntPtr, Int32, IntPtr), int Function(int, int, int)>('SetWindowLongPtrW');
  static final _sendMessage = _user32?.lookupFunction<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr), int Function(int, int, int, int)>('SendMessageW');
  static final _releaseCapture = _user32?.lookupFunction<Int32 Function(), int Function()>('ReleaseCapture');
  static final _removeProp = _user32?.lookupFunction<IntPtr Function(IntPtr, Pointer<Utf16>), int Function(int, Pointer<Utf16>)>('RemovePropW');

  static const _topmost = -1, _notTopmost = -2;
  static const _noSize = 0x1, _noMove = 0x2, _noActivate = 0x10;
  static const _noZOrder = 0x4, _frameChanged = 0x20;
  static const _restore = 9, _maximize = 3;
  static const _gwlStyle = -16;
  static const _wsCaption = 0xC00000, _wsMaximizeBox = 0x10000, _wsMinimizeBox = 0x20000, _wsSysMenu = 0x80000;
  static const _wmNcLButtonDown = 0xA1, _htCaption = 2, _htBottomRight = 17;

  static int? _handle;

  /// Lumtub's own top-level window: the runner's window class in this
  /// process, so a second copy of the app is never moved.
  static int? get handle {
    if (_handle != null || _user32 == null) return _handle;
    final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final pid = calloc<Uint32>();
    try {
      final own = _getCurrentProcessId!();
      var window = 0;
      while ((window = _findWindowEx!(0, window, className, nullptr)) != 0) {
        _getWindowThreadProcessId!(window, pid);
        if (pid.value == own) return _handle = window;
      }
      return null;
    } finally {
      calloc.free(className);
      calloc.free(pid);
    }
  }

  /// Keeps the window above the others, or lets it go back among them.
  static bool setTopmost(bool on) {
    final window = handle;
    if (window == null) return false;
    return _setWindowPos!(window, on ? _topmost : _notTopmost, 0, 0, 0, 0, _noMove | _noSize | _noActivate) != 0;
  }

  static ({int left, int top, int width, int height, bool maximized, int style})? _before;

  /// Where the picture-in-picture window was last left: its corner and
  /// width in logical pixels, so it comes back there next time.
  static ({int left, int top, double width})? _lastPip;

  /// 画中画, as PiliNara's desktop one: no title bar or caption, above the
  /// other windows, a picture of the video's [aspect] ratio whose short side
  /// is [shortSide] logical pixels. The runner keeps the ratio while it is
  /// resized (window_placement.cpp, flutter_window.cpp). Returns false when
  /// the window is not there.
  static bool enterPip({required double aspect, double shortSide = 280}) {
    final window = handle;
    if (window == null || _before != null) return false;
    final rect = calloc<_Rect>();
    final client = calloc<_Rect>();
    final monitor = calloc<_MonitorInfo>()..ref.size = sizeOf<_MonitorInfo>();
    final name = _pipProperty.toNativeUtf16();
    try {
      final maximized = _isZoomed!(window) != 0;
      if (maximized) _showWindow!(window, _restore);
      if (_getWindowRect!(window, rect) == 0) return false;
      final style = _getWindowLongPtr!(window, _gwlStyle);
      _before = (left: rect.ref.left, top: rect.ref.top, width: rect.ref.right - rect.ref.left, height: rect.ref.bottom - rect.ref.top, maximized: maximized, style: style);
      if (_getMonitorInfo!(_monitorFromWindow!(window, 2), monitor) == 0) return false;
      final scale = _scaleOf(window);
      // The ratio and this marker are read by the runner; placement is not
      // saved while it is on, so the next launch opens at the usual size.
      _setProp!(window, name, (pipAspectOf(aspect) * 1000).round());
      _setWindowLongPtr!(window, _gwlStyle, style & ~(_wsCaption | _wsMaximizeBox | _wsMinimizeBox | _wsSysMenu));
      _setWindowPos!(window, _topmost, 0, 0, 0, 0, _noMove | _noSize | _noActivate | _frameChanged);
      _setBorder(window, visible: false);
      final (:width, :height) = pipSizeFor(aspect, shortSide: shortSide);
      final (:extraWidth, :extraHeight) = _frameOf(window, rect, client);
      final w = (width * scale).round() + extraWidth;
      final h = (height * scale).round() + extraHeight;
      final area = monitor.ref.work;
      final margin = (16 * scale).round();
      final last = _lastPip;
      var left = area.right - w - margin, top = area.bottom - h - margin;
      if (last != null) {
        // The same corner as last time, kept on the screen.
        left = last.left.clamp(area.left, max(area.left, area.right - w));
        top = last.top.clamp(area.top, max(area.top, area.bottom - h));
      }
      return _setWindowPos!(window, _topmost, left, top, w, h, _frameChanged) != 0;
    } finally {
      calloc.free(rect);
      calloc.free(client);
      calloc.free(monitor);
      calloc.free(name);
    }
  }

  /// A different video: the same width, the height of its new [aspect].
  static bool setPipAspect(double aspect) {
    final window = handle;
    if (window == null || _before == null) return false;
    final rect = calloc<_Rect>();
    final client = calloc<_Rect>();
    final name = _pipProperty.toNativeUtf16();
    try {
      _setProp!(window, name, (pipAspectOf(aspect) * 1000).round());
      final (:extraWidth, :extraHeight) = _frameOf(window, rect, client);
      final width = client.ref.right - client.ref.left;
      return _setWindowPos!(window, 0, 0, 0, width + extraWidth, (width / pipAspectOf(aspect)).round() + extraHeight, _noMove | _noActivate | _noZOrder) != 0;
    } finally {
      calloc.free(rect);
      calloc.free(client);
      calloc.free(name);
    }
  }

  /// Frame size around the client area, of the window now.
  static ({int extraWidth, int extraHeight}) _frameOf(int window, Pointer<_Rect> rect, Pointer<_Rect> client) {
    _getWindowRect!(window, rect);
    _getClientRect!(window, client);
    return (
      extraWidth: rect.ref.right - rect.ref.left - (client.ref.right - client.ref.left),
      extraHeight: rect.ref.bottom - rect.ref.top - (client.ref.bottom - client.ref.top),
    );
  }

  static double _scaleOf(int window) {
    final dpi = _getDpiForWindow!(window);
    return (dpi == 0 ? 96 : dpi) / 96;
  }

  /// Puts the window back where and how it was before [enterPip]: its
  /// caption, size, position and maximized state.
  static bool exitPip({bool keepOnTop = false}) {
    final window = handle;
    final before = _before;
    if (window == null || before == null) return false;
    _before = null;
    final rect = calloc<_Rect>();
    final client = calloc<_Rect>();
    final name = _pipProperty.toNativeUtf16();
    try {
      if (_getWindowRect!(window, rect) != 0 && _getClientRect!(window, client) != 0) {
        _lastPip = (left: rect.ref.left, top: rect.ref.top, width: (client.ref.right - client.ref.left) / _scaleOf(window));
      }
      _removeProp!(window, name);
      _setWindowLongPtr!(window, _gwlStyle, before.style);
      _setBorder(window, visible: true);
      final ok = _setWindowPos!(window, keepOnTop ? _topmost : _notTopmost, before.left, before.top, before.width, before.height, _frameChanged) != 0;
      if (before.maximized) _showWindow!(window, _maximize);
      return ok;
    } finally {
      calloc.free(rect);
      calloc.free(client);
      calloc.free(name);
    }
  }

  /// Lets the user drag the window by pressing on the picture, as on a
  /// title bar. Call it from a pointer-down; it returns when the button is
  /// released.
  static void startDrag() => _startNonClient(_htCaption);

  /// The same for resizing from the bottom-right corner; the runner keeps
  /// the video's ratio.
  static void startResize() => _startNonClient(_htBottomRight);

  static void _startNonClient(int hit) {
    final window = handle;
    if (window == null) return;
    _releaseCapture!();
    _sendMessage!(window, _wmNcLButtonDown, hit, 0);
  }

  /// Read by the runner's window_placement.cpp; keep the two in step.
  static const _pipProperty = 'LumtubPictureInPicture';
}

final class _Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

final class _MonitorInfo extends Struct {
  @Uint32()
  external int size;
  external _Rect monitor;
  external _Rect work;
  @Uint32()
  external int flags;
}
